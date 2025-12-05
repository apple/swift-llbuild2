// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCBasic
import XCTest
import llbuild2fx

final class SpawnProcessTests: XCTestCase {
    var ctx: Context!
    var streamAccumulator: StreamAccumulator!

    override func setUp() {
        ctx = Context()
        ctx.db = LLBInMemoryCASDatabase(group: LLBMakeDefaultDispatchGroup())
        streamAccumulator = StreamAccumulator()
        ctx.streamingLogHandler = streamAccumulator
    }

    func testCancellation() async throws {
        let taskCancellationRegistry = TaskCancellationRegistry()
        ctx.taskCancellationRegistry = taskCancellationRegistry
        ctx.group = ctx.db.group

        struct MyValue: FXValue, Codable {
            let value: Int32
        }

        struct MyKey: AsyncFXKey {
            typealias ValueType = MyValue

            func computeValue(_ fi: llbuild2fx.FXFunctionInterface<MyKey>, _ ctx: Context) async throws -> MyValue {
                let process = try await llbuild2fxTests.makeProcess(ctx: ctx, "/bin/sh", ["-c", "sleep 5"])
                async let result = process.run(ctx)
                ctx.taskCancellationRegistry?.cancelAllTasks()
                return try await MyValue(value: result.exitCode)
            }
        }

        let engine = FXEngine(group: ctx.group, db: ctx.db, functionCache: nil, executor: FXLocalExecutor())

        do {
            _ = try await engine.build(key: MyKey(), ctx).get()
        } catch let error as FXError {
            switch error {
            case .valueComputationError(_, _, let error, _):
                XCTAssertTrue(error is SpawnProcess.FXSpawnError)
            default:
                throw error
            }
        }
    }

    func testCapturesStdout() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output"])
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertLocalStdout(hasContents: "output\n", inResult: result)
        try await assertStreamingStdout(hasContents: "output\n")
    }

    func testCapturesStderr() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo error >&2"])
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertLocalStderr(hasContents: "error\n", inResult: result)
        try await assertStreamingStderr(hasContents: "error\n")
    }

    func testCapturesBothStdoutAndStderr() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output; echo error >&2"])
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertLocalStdout(hasContents: "output\n", inResult: result)
        try await assertStreamingStdout(hasContents: "output\n")
        try await assertLocalStderr(hasContents: "error\n", inResult: result)
        try await assertStreamingStderr(hasContents: "error\n")
    }

    func testReadsInput() async throws {
        let process = try await llbuild2fxTests.makeProcess(ctx: ctx, "/bin/cat", [.inputPath(RelativePath(validating: "stdin.txt"))], stdinContents: "input data")
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertLocalStdout(hasContents: "input data", inResult: result)
        try await assertStreamingStdout(hasContents: "input data")
    }

    func testCanMergeLocalOutputs() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output; echo error >&2"], stdoutDestination: "merged.txt", stderrDestination: "merged.txt")
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertStreamingStdout(hasContents: "output\n")
        try await assertStreamingStderr(hasContents: "error\n")

        try await result.treeID.materialize(ctx) { rootPath in
            let localOutput = try String(contentsOfFile: rootPath.appending(component: "merged.txt").pathString, encoding: .utf8)
            // There are no guarantees on the way stdout and stderr will be interleaved, but the full contents should be there in some order.
            XCTAssert(localOutput == "output\nerror\n" || localOutput == "error\noutput\n", "Unexpected merged output: \"\(localOutput)\"")
        }
    }

    func testCanMergeStreamingOutputs() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output; echo error >&2"], stdoutStreamingDestination: "merged.log", stderrStreamingDestination: "merged.log")
        let result = try await process.run(ctx)
        XCTAssertEqual(result.exitCode, 0)
        try await assertLocalStdout(hasContents: "output\n", inResult: result)
        try await assertLocalStderr(hasContents: "error\n", inResult: result)

        let streamingOutput = try XCTUnwrap(streamAccumulator.accumulatedLogs["merged.log"], "Streaming channel \"merged.log\" unexpectedly empty.")
        // There are no guarantees on the way stdout and stderr will be interleaved, but the full contents should be there in some order.
        XCTAssert(streamingOutput == "output\nerror\n" || streamingOutput == "error\noutput\n", "Unexpected merged output: \"\(streamingOutput)\"")
    }

    func testCancelsWhenDeadlineIsReached() async throws {
        let process = try await makeProcess("/bin/sleep", ["1d"])
        ctx.fxDeadline = Date(timeIntervalSinceNow: 0.1)
        do {
            _ = try await process.run(ctx)
        } catch SpawnProcess.FXSpawnError.failure(outputTree: _, underlyingError: is ProcessTerminationError) {
            // Assert that we're close to the scheduled deadline.
            XCTAssertEqual(ctx.fxDeadline!.timeIntervalSinceNow, 0, accuracy: 0.1)
            return
        }
        XCTFail("Process didn't throw a ProcessTerminationError when the deadline was reached.")
    }

    // Regression test for issues caused by https://github.com/swiftlang/swift/issues/80791.
    func testLongDeadlineDoesntCauseEarlyCancellation() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output"])
        var localCtx: Context = ctx
        localCtx.fxDeadline = Date.distantFuture
        let result = try await process.run(localCtx)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testKeepsOutputWhenCancelled() async throws {
        let process = try await makeProcess("/bin/sh", ["-c", "echo output; sleep 1d"])
        ctx.fxDeadline = Date(timeIntervalSinceNow: 0.1)
        do {
            _ = try await process.run(ctx)
        } catch SpawnProcess.FXSpawnError.failure(outputTree: let outputTree, underlyingError: is ProcessTerminationError) {
            try await ProcessOutputTreeID(outputTree).materialize(ctx) { rootPath in
                let fileContents = try String(contentsOfFile: rootPath.appending(component: "stdout.txt").pathString, encoding: .utf8)
                try XCTAssertEqual(fileContents, "output\n")
            }
            try await assertStreamingStdout(hasContents: "output\n")
            return
        }
        XCTFail("Process didn't throw a ProcessTerminationError when the deadline was reached.")
    }

    func testGathersDiagnosticsWhenCancelled() async throws {
        let process = try await makeProcess("/bin/sleep", ["1d"])
        ctx.fxDeadline = Date(timeIntervalSinceNow: 0.1)
        let diagnosticsDataId = try await ctx.db.put(data: LLBByteBuffer(string: "example diagnostics"), ctx).get()
        ctx.fxDiagnosticsGatherer = MockDiagnosticsGatherer(returnValue: FXDiagnostics(dataID: diagnosticsDataId))
        do {
            _ = try await process.run(ctx)
        } catch SpawnProcess.FXSpawnError.failure(outputTree: _, underlyingError: let underlyingError as ProcessTerminationError) {
            let diagnostics = try XCTUnwrap(underlyingError.diagnostics, "Diagnostics gatherer wasn't run.")
            let actualDiagnostics = try await String(buffer: ctx.db.get(diagnostics.get().dataID, ctx).get()!.data)
            XCTAssertEqual(actualDiagnostics, "example diagnostics")
            return
        }
        XCTFail("Process didn't throw a ProcessTerminationError when the deadline was reached.")
    }

    // MARK: - Helpers for creating SpawnProcess instances and asserting on their outputs.

    func makeProcess(
        _ executable: String, _ arguments: [String], stdinContents: String = "", stdoutDestination: String = "stdout.txt", stderrDestination: String = "stderr.txt",
        stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log"
    ) async throws
        -> SpawnProcess
    {
        try await llbuild2fxTests.makeProcess(
            ctx: ctx,
            executable, arguments.map(ProcessSpec.RuntimeValue.literal), stdinContents: stdinContents, stdoutDestination: stdoutDestination, stderrDestination: stderrDestination,
            stdoutStreamingDestination: stdoutStreamingDestination, stderrStreamingDestination: stderrStreamingDestination)
    }

    func assert(outputFile: String, hasContents expectedContents: String, inResult result: SpawnProcessResult) async throws {
        try await result.treeID.materialize(ctx) { rootPath in
            let fileContents = try String(contentsOfFile: rootPath.appending(component: outputFile).pathString, encoding: .utf8)
            try XCTAssertEqual(fileContents, expectedContents)
        }
    }
    func assertLocalStdout(hasContents expectedContents: String, inResult result: SpawnProcessResult) async throws {
        return try await assert(outputFile: "stdout.txt", hasContents: expectedContents, inResult: result)
    }
    func assertLocalStderr(hasContents expectedContents: String, inResult result: SpawnProcessResult) async throws {
        return try await assert(outputFile: "stderr.txt", hasContents: expectedContents, inResult: result)
    }

    func assert(streamingChannel: String, hasContents expectedContents: String) async throws {
        let actualContents = try XCTUnwrap(streamAccumulator.accumulatedLogs[streamingChannel], "Streaming channel \"\(streamingChannel)\" unexpectedly empty.")
        XCTAssertEqual(actualContents, expectedContents)
    }
    func assertStreamingStdout(hasContents expectedContents: String) async throws {
        return try await assert(streamingChannel: "stdout.log", hasContents: expectedContents)
    }
    func assertStreamingStderr(hasContents expectedContents: String) async throws {
        return try await assert(streamingChannel: "stderr.log", hasContents: expectedContents)
    }
}

class StreamAccumulator: StreamingLogHandler {
    var accumulatedLogs: [String: String] = [:]

    func streamLog(spec: ProcessSpec, channel: String, _ data: LLBByteBuffer) {
        accumulatedLogs[channel, default: ""].append(String(buffer: data))
    }
}

struct MockDiagnosticsGatherer: FXDiagnosticsGathering {
    var returnValue: FXDiagnostics

    func gatherDiagnostics(pid: Int32?, _ ctx: Context) async throws -> FXDiagnostics {
        return returnValue
    }
}

func makeProcess(
    ctx: Context, _ executable: String, _ arguments: [ProcessSpec.RuntimeValue], stdinContents: String = "", stdoutDestination: String = "stdout.txt", stderrDestination: String = "stderr.txt",
    stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log"
) async throws
    -> SpawnProcess
{
    try await withTemporaryDirectory(removeTreeOnDeinit: true) { tempDir in
        let stdinPath = try tempDir.appending(RelativePath(validating: "stdin.txt"))
        try await stdinContents.write(toFileAt: .init(stdinPath.pathString))
        let inputTreeId = ProcessInputTreeID(dataID: try await LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).get())

        let processSpec = try ProcessSpec(
            executable: .absolutePath(.init(validating: executable)),
            arguments: arguments,
            stdinSource: RelativePath(validating: "stdin.txt"),
            stdoutDestination: RelativePath(validating: stdoutDestination),
            stderrDestination: RelativePath(validating: stderrDestination),
            stdoutStreamingDestination: stdoutStreamingDestination,
            stderrStreamingDestination: stderrStreamingDestination)

        return SpawnProcess(inputTree: inputTreeId, spec: processSpec)
    }
}

func makeProcess(
    ctx: Context, _ executable: String, _ arguments: [String], stdinContents: String = "", stdoutDestination: String = "stdout.txt", stderrDestination: String = "stderr.txt",
    stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log"
) async throws
    -> SpawnProcess
{
    try await makeProcess(
        ctx: ctx,
        executable, arguments.map(ProcessSpec.RuntimeValue.literal), stdinContents: stdinContents, stdoutDestination: stdoutDestination, stderrDestination: stderrDestination,
        stdoutStreamingDestination: stdoutStreamingDestination, stderrStreamingDestination: stderrStreamingDestination)
}
