// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import TSCBasic
import XCTest
import llbuild2Testing
import llbuild2fx

final class SpawnProcessTests: XCTestCase {
    var ctx: Context!
    var streamAccumulator: StreamAccumulator!

    override func setUp() {
        ctx = Context()
        ctx.db = FXInMemoryCASDatabase(group: FXMakeDefaultDispatchGroup())
        ctx.group = ctx.db.group
        ctx.fxCASTreeService = FXLocalCASTreeService()
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
        let diagnosticsDataId = try await ctx.db.put(data: FXByteBuffer(string: "example diagnostics"), ctx).get()
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

    func testRoundTripSerializes() async throws {
        let original = try await makeProcess("/bin/sh", ["-c", "echo output"])
        let copied = try SpawnProcess(from: original.asCASObject())

        XCTAssertEqual(copied.inputTree, original.inputTree)
        XCTAssertEqual(try copied.spec.fxEncodeJSON(), try original.spec.fxEncodeJSON())
        XCTAssertEqual(copied.initialOutputTree, original.initialOutputTree)
    }

    func testRoundTripSerializesWithInitialOutputTree() async throws {
        let original = try await makeProcess("/bin/sh", ["-c", "echo output"], initialOutputTree: LLBDeclFileTree.dir(["extraOutput.txt": .file("foo")]))
        let copied = try SpawnProcess(from: original.asCASObject())

        XCTAssertEqual(copied.inputTree, original.inputTree)
        XCTAssertEqual(try copied.spec.fxEncodeJSON(), try original.spec.fxEncodeJSON())
        XCTAssertEqual(copied.initialOutputTree, original.initialOutputTree)
    }

    // MARK: - Helpers for creating SpawnProcess instances and asserting on their outputs.

    func makeProcess(
        _ executable: String, _ arguments: [String], stdinContents: String = "", stdoutDestination: String = "stdout.txt", stderrDestination: String = "stderr.txt",
        stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log", initialOutputTree: LLBDeclFileTree? = nil
    ) async throws
        -> SpawnProcess
    {
        try await llbuild2fxTests.makeProcess(
            ctx: ctx,
            executable, arguments, stdinContents: stdinContents, stdoutDestination: stdoutDestination, stderrDestination: stderrDestination,
            stdoutStreamingDestination: stdoutStreamingDestination, stderrStreamingDestination: stderrStreamingDestination, initialOutputTree: initialOutputTree)
    }

    func assert(outputFile: String, hasContents expectedContents: String, inResult result: SpawnProcessResult) async throws {
        let fileTree = try await FXCASFileTree.load(id: result.treeID.dataID, from: ctx.db, ctx).get()
        guard let file = fileTree.lookup(outputFile) else {
            XCTFail("File \"\(outputFile)\" not found in spawn process result")
            return
        }
        let blob = try await FXCASBlob.parse(id: file.id, in: ctx.db, ctx).get().read(ctx).get()
        let fileContents = String(bytes: blob, encoding: .utf8)

        XCTAssertEqual(fileContents, expectedContents)
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

    func streamLog(channel: String, _ data: FXByteBuffer) {
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
    stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log", initialOutputTree: ProcessOutputTreeID? = nil
) async throws
    -> SpawnProcess
{
    let inputDeclTree = LLBDeclFileTree.dir(["stdin.txt": .file(stdinContents)])
    let inputDataID: FXDataID = try await FXCASFSClient(ctx.db).store(inputDeclTree, ctx).get()
    let inputTreeId = ProcessInputTreeID(dataID: inputDataID)

    let processSpec = try ProcessSpec(
        executable: .absolutePath(.init(validating: executable)),
        arguments: arguments,
        stdinSource: RelativePath(validating: "stdin.txt"),
        stdoutDestination: RelativePath(validating: stdoutDestination),
        stderrDestination: RelativePath(validating: stderrDestination),
        stdoutStreamingDestination: stdoutStreamingDestination,
        stderrStreamingDestination: stderrStreamingDestination)

    return SpawnProcess(inputTree: inputTreeId, spec: processSpec, initialOutputTree: initialOutputTree)
}

func makeProcess(
    ctx: Context, _ executable: String, _ arguments: [String], stdinContents: String = "", stdoutDestination: String = "stdout.txt", stderrDestination: String = "stderr.txt",
    stdoutStreamingDestination: String = "stdout.log", stderrStreamingDestination: String = "stderr.log", initialOutputTree: LLBDeclFileTree? = nil
) async throws
    -> SpawnProcess
{
    let initialOutputTreeID: ProcessOutputTreeID? =
        if let declTree = initialOutputTree { try await ProcessOutputTreeID(dataID: FXCASFSClient(ctx.db).store(declTree, ctx).get()) } else { nil }

    return try await llbuild2fxTests.makeProcess(
        ctx: ctx,
        executable, arguments.map(ProcessSpec.RuntimeValue.literal), stdinContents: stdinContents, stdoutDestination: stdoutDestination, stderrDestination: stderrDestination,
        stdoutStreamingDestination: stdoutStreamingDestination, stderrStreamingDestination: stderrStreamingDestination, initialOutputTree: initialOutputTreeID)
}
