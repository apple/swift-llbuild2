// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import AsyncProcess2
import Foundation
import NIOCore
import TSCBasic
import TSCUtility
import TSFFutures
import _NIOFileSystem

private struct ProcessTerminationError: Error {
    var diagnostics: Result<FXDiagnostics, Error>?
}

public struct ProcessSpec: Codable, Sendable {
    public enum Executable: Codable, Sendable {
        case absolutePath(AbsolutePath)
        case inputPath(RelativePath)
    }

    public enum RuntimeValue: Codable, Equatable, Sendable {
        case literal(String)
        case inputPath(RelativePath)
        case outputPath(RelativePath)
        case sequence(values: [RuntimeValue], separator: String)
    }

    let executable: Executable
    let arguments: [RuntimeValue]
    let environment: [String: RuntimeValue]

    let stdinSource: RelativePath?
    let stdoutDestination: RelativePath?
    let stderrDestination: RelativePath?

    /// Paths as recognized by the Context's `fileHandleGenerator`.
    let stdoutStreamingDestination: String?
    let stderrStreamingDestination: String?

    public init(
        executable: Executable,
        arguments: [RuntimeValue] = [],
        environment: [String: RuntimeValue] = [:],
        stdinSource: RelativePath? = nil,
        stdoutDestination: RelativePath? = nil,
        stderrDestination: RelativePath? = nil,
        stdoutStreamingDestination: String? = "stdout.log",
        stderrStreamingDestination: String? = "stderr.log"
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdinSource = stdinSource
        self.stdoutDestination = stdoutDestination
        self.stderrDestination = stderrDestination
        self.stdoutStreamingDestination = stdoutStreamingDestination
        self.stderrStreamingDestination = stderrStreamingDestination
    }

    enum ProcessSpecError: Error {
        case unableToCreateFile(RelativePath)
        case unableToCreateFileHandle(RelativePath)
    }

    func withOptionalBufferedWriter<T>(_ handle: WriteFileHandle?, body: (inout BufferedWriter<WriteFileHandle>?) async throws -> T) async throws -> T {
        if let handle = handle {
            return try await handle.withBufferedWriter { writer in
                var maybeWriter: BufferedWriter<WriteFileHandle>? = writer
                defer { if let finalWriter = maybeWriter { writer = finalWriter } }
                return try await body(&maybeWriter)
            }
        } else {
            var writer: BufferedWriter<WriteFileHandle>? = nil
            return try await body(&writer)
        }
    }

    func handleOutput(stream: ChunkSequence, for localDestination: WriteFileHandle?, and streamingDestination: String?, _ ctx: Context) async throws {
        let streamingWrite: (ByteBuffer) async throws -> Void
        if let streamingLogHandler = ctx.streamingLogHandler, let channel = streamingDestination {
            streamingWrite = { try await streamingLogHandler.streamLog(channel: channel, $0) }
        } else {
            streamingWrite = { _ in () }
        }

        try await withOptionalBufferedWriter(localDestination) { bufferedWriter in
            for try await chunk in stream {
                // Write to both the local file and the streaming log endpoint in parallel.
                async let localWriteResult = bufferedWriter?.write(contentsOf: chunk)
                async let streamingWriteResult: () = streamingWrite(chunk)
                _ = try await (localWriteResult, streamingWriteResult)
            }
        }
    }

    fileprivate func process(inputPath: AbsolutePath, outputPath: AbsolutePath, _ ctx: Context) async throws -> ProcessExitReason {
        @Sendable func runtimeValueMapper(_ value: RuntimeValue) -> String {
            switch value {
            case .literal(let v):
                return v
            case .inputPath(let path):
                return inputPath.appending(path).pathString
            case .outputPath(let path):
                return outputPath.appending(path).pathString
            case .sequence(let values, let separator):
                return String(
                    values.map {
                        runtimeValueMapper($0)
                    }.joined(separator: separator))
            }
        }

        @Sendable func handleOutput2(stream: ChunkSequence, for localDestination: RelativePath?, and streamingDestination: String?) async throws {
            guard let localDestination = localDestination else {
                return try await handleOutput(stream: stream, for: nil, and: streamingDestination, ctx)
            }
            let localPath = FilePath(runtimeValueMapper(.outputPath(localDestination)))
            // TODO: Think about what happens when stdout and stderr go to the same place.
            return try await FileSystem.shared.withFileHandle(forWritingAt: localPath, options: OpenOptions.Write.newFile(replaceExisting: false)) { localHandle in
                return try await handleOutput(stream: stream, for: localHandle, and: streamingDestination, ctx)
            }
        }

        let exePath: AbsolutePath
        switch executable {
        case .absolutePath(let path):
            exePath = path
        case .inputPath(let path):
            exePath = inputPath.appending(path)
        }

        let stdinPath: String
        if let stdinRelative = stdinSource {
            stdinPath = runtimeValueMapper(.inputPath(stdinRelative))
        } else {
            stdinPath = "/dev/null"
        }

        return try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(stdinPath)) { stdin in
            let exe = ProcessExecutor(
                executable: exePath.pathString,
                arguments.map(runtimeValueMapper),
                environment: environment.mapValues(runtimeValueMapper),
                standardInput: stdin.readChunks(),
                standardOutput: .stream,
                standardError: .stream,
                logger: ctx.logger ?? ProcessExecutor.disableLogging)

            enum WhoReturned {
                case run(ProcessExitReason)
                case deadline(Result<FXDiagnostics, Error>?)
            }

            return try await withThrowingTaskGroup(of: WhoReturned.self) { group in
                ctx.logger?.debug("Running process: \(exe)")
                defer { ctx.logger?.debug("Finished running process: \(exe)") }

                // Main task.
                group.addTask {
                    // Run the process and handle its outputs in parallel, ensuring we fully consume the process's outputs.
                    async let runExe = exe.run()
                    async let handleStdout: () = handleOutput2(stream: exe.standardOutput, for: stdoutDestination, and: stdoutStreamingDestination)
                    async let handleStderr: () = handleOutput2(stream: exe.standardError, for: stderrDestination, and: stderrStreamingDestination)
                    let (result, _, _) = try await (runExe, handleStdout, handleStderr)
                    return .run(result)
                }

                // Timeout / diagnostics-gathering task.
                if let deadline = ctx.fxDeadline {
                    group.addTask {
                        // Wait until the deadline.
                        // (`try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))` is only available in macOS 13.0 or newer.)
                        let deadlineSeconds = deadline.timeIntervalSinceNow
                        if deadlineSeconds > 0 {
                            let deadlineNanoseconds = UInt64(exactly: (deadlineSeconds * 1_000_000_000).rounded()) ?? UInt64.max
                            try await Task.sleep(nanoseconds: deadlineNanoseconds)
                        }

                        // If we don't have a diagnostics gatherer, just return a signal that the deadline was reached.
                        guard let gatherer = ctx.fxDiagnosticsGatherer else { return .deadline(nil) }

                        // Gather diagnostics about the potentially-hung task.
                        let diagnostics: Result<FXDiagnostics, Error>  // Workaround for lack of async initializer on `Result`.
                        do { diagnostics = .success(try await gatherer.gatherDiagnostics(pid: exe.bestEffortProcessIdentifier, ctx)) } catch { diagnostics = .failure(error) }
                        return .deadline(diagnostics)
                    }
                }

                switch try await group.next() {
                case .run(let result):
                    // Ran successfully; cancel the timeout and return the result.
                    ctx.logger?.debug("Process finished: \(exe); result: \(result)")
                    group.cancelAll()
                    return result
                case .deadline(let diagnostics):
                    ctx.logger?.debug("Process timed out: \(exe)")
                    // Timeout triggered and gathered diagnostics; cancel the running process and throw an error containing the diagnostics.
                    group.cancelAll()
                    throw ProcessTerminationError(diagnostics: diagnostics)
                case .none:
                    fatalError("unreachable")
                }
            }
        }
    }
}

struct ProcessInputTree: FXTreeID {
    let dataID: LLBDataID
}

extension SpawnProcess: AsyncFXAction {
    public typealias ValueType = SpawnProcessResult

    private enum SpawnProcessError: Swift.Error {
        case emptyRefs
        case tooManyRefs
    }

    public var refs: [LLBDataID] { [inputTree.dataID] }
    public var codableValue: ProcessSpec { spec }

    public init(refs: [LLBDataID], codableValue: ProcessSpec) throws {
        guard !refs.isEmpty else {
            throw SpawnProcessError.emptyRefs
        }
        guard refs.count == 1 else {
            throw SpawnProcessError.tooManyRefs
        }

        let treeID = refs[0]

        self.init(inputTree: ProcessInputTreeID(dataID: treeID), spec: codableValue)
    }
}

public struct SpawnProcess {
    let inputTree: ProcessInputTreeID

    let spec: ProcessSpec

    let initialOutputTree: ProcessOutputTreeID?

    public init(
        inputTree: ProcessInputTreeID,
        spec: ProcessSpec,
        initialOutputTree: ProcessOutputTreeID? = nil
    ) {
        self.inputTree = inputTree
        self.spec = spec
        self.initialOutputTree = initialOutputTree
    }

    enum FXSpawnError: Error {
        case failure(outputTree: LLBDataID, underlyingError: Error)
        case recoveryUploadFailure(uploadError: Error, originalError: Error)
    }

    public func run(_ ctx: Context) async throws -> SpawnProcessResult {
        try await inputTree.materialize(ctx) { inputPath in
            try await withTemporaryDirectory(ctx) { outputPath in
                if let initialOutputTree = initialOutputTree {
                    try await LLBCASFileTree.export(initialOutputTree.dataID, from: ctx.db, to: outputPath, stats: LLBCASFileTree.ExportProgressStatsInt64(), ctx).get()
                }

                do {
                    let exitCode = try await spec.process(inputPath: inputPath, outputPath: outputPath, ctx).asShellExitCode
                    let treeID = try await LLBCASFileTree.import(path: outputPath, to: ctx.db, ctx).get()
                    return SpawnProcessResult(treeID: .init(dataID: treeID), exitCode: Int32(truncatingIfNeeded: exitCode))
                } catch (let error) {
                    let treeID: LLBDataID
                    do {
                        treeID = try await LLBCASFileTree.import(path: outputPath, to: ctx.db, ctx).get()
                    } catch (let uploadError) {
                        throw FXSpawnError.recoveryUploadFailure(uploadError: uploadError, originalError: error)
                    }
                    throw FXSpawnError.failure(outputTree: treeID, underlyingError: error)
                }
            }
        }
    }
}

extension SpawnProcess: Encodable {}

public struct ProcessInputTreeID: FXSingleDataIDValue, FXTreeID {
    public let dataID: LLBDataID
    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}

public struct ProcessOutputTreeID: FXSingleDataIDValue, FXTreeID {
    public let dataID: LLBDataID
    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}

public struct SpawnProcessResult: FXValue, FXTreeID {
    public let treeID: ProcessOutputTreeID
    public let exitCode: Int32

    public init(treeID: ProcessOutputTreeID, exitCode: Int32) {
        self.treeID = treeID
        self.exitCode = exitCode
    }

    public var dataID: LLBDataID {
        treeID.dataID
    }

    public var refs: [LLBDataID] {
        [
            dataID
        ]
    }

    public var codableValue: Int32 {
        exitCode
    }

    enum Error: Swift.Error {
        case notEnoughRefs
        case tooManyRefs
    }

    public init(refs: [LLBDataID], codableValue: Int32) throws {
        guard !refs.isEmpty else {
            throw Error.notEnoughRefs
        }

        guard refs.count == 1 else {
            throw Error.tooManyRefs
        }

        treeID = ProcessOutputTreeID(dataID: refs[0])
        exitCode = codableValue
    }
}
