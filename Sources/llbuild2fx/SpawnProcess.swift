// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import AsyncAlgorithms
import Foundation
import NIOCore
import TSCBasic
import TSCUtility
import TSFAsyncProcess
import TSFFutures
import _NIOFileSystem

public struct ProcessTerminationError: Error {
    public var diagnostics: Result<FXDiagnostics, Error>?
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
        case temporaryDirectory(RelativePath)
        case sequence(values: [RuntimeValue], separator: String)
    }

    public struct SpawnOptions: Codable, Equatable, Sendable {
        public var changedWorkingDirectory: RuntimeValue?

        public static var `default`: SpawnOptions {
            .init(changedWorkingDirectory: nil)
        }
    }

    public let executable: Executable
    public let arguments: [RuntimeValue]
    public let environment: [String: RuntimeValue]

    public let spawnOptions: SpawnOptions

    public let stdinSource: RelativePath?
    public let stdoutDestination: RelativePath?
    public let stderrDestination: RelativePath?

    /// Paths as recognized by the Context's `fileHandleGenerator`.
    public let stdoutStreamingDestination: String?
    public let stderrStreamingDestination: String?

    /// Path under which temporary directories will be created.
    public let temporaryDirectoryBase: AbsolutePath?

    public init(
        executable: Executable,
        arguments: [RuntimeValue] = [],
        environment: [String: RuntimeValue] = [:],
        spawnOptions: SpawnOptions = .default,
        stdinSource: RelativePath? = nil,
        stdoutDestination: RelativePath? = nil,
        stderrDestination: RelativePath? = nil,
        stdoutStreamingDestination: String? = "stdout.log",
        stderrStreamingDestination: String? = "stderr.log",
        temporaryDirectoryBase: AbsolutePath? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.spawnOptions = spawnOptions
        self.stdinSource = stdinSource
        self.stdoutDestination = stdoutDestination
        self.stderrDestination = stderrDestination
        self.stdoutStreamingDestination = stdoutStreamingDestination
        self.stderrStreamingDestination = stderrStreamingDestination
        self.temporaryDirectoryBase = temporaryDirectoryBase
    }

    fileprivate func process(inputPath: AbsolutePath, outputPath: AbsolutePath, tmpDir: AbsolutePath, _ ctx: Context) async throws -> ProcessExitReason {
        @Sendable func runtimeValueMapper(_ value: RuntimeValue) -> String {
            switch value {
            case .literal(let v):
                return v
            case .inputPath(let path):
                return inputPath.appending(path).pathString
            case .outputPath(let path):
                return outputPath.appending(path).pathString
            case .temporaryDirectory(let path):
                return tmpDir.appending(path).pathString
            case .sequence(let values, let separator):
                return String(
                    values.map {
                        runtimeValueMapper($0)
                    }.joined(separator: separator))
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
                spawnOptions: spawnOptions.toProcessExecutorSpawnOptions(runtimeValueMapper),
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
                    // Merge stdout and stderr into a single tagged stream so we don't have to worry about data races when stdout and stderr get written to the same destination.
                    let taggedOutputs = merge(
                        await exe.standardOutput.map { ($0, OutputSource.stdout) },
                        await exe.standardError.map { ($0, OutputSource.stderr) }
                    )
                    let stdoutPath = stdoutDestination.map { FilePath(runtimeValueMapper(.outputPath($0))) }
                    let stderrPath = stderrDestination.map { FilePath(runtimeValueMapper(.outputPath($0))) }
                    async let handleOutputs: () = handleOutputs(taggedOutputs, stdoutPath: stdoutPath, stderrPath: stderrPath, ctx)
                    let (result, _) = try await (runExe, handleOutputs)
                    return .run(result)
                }

                // Timeout / diagnostics-gathering task.
                if let deadline = ctx.fxDeadline {
                    group.addTask {
                        // Wait until the deadline.
                        // (`try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))` is only available in macOS 13.0 or newer.)
                        let deadlineSeconds = deadline.timeIntervalSinceNow
                        if deadlineSeconds > 0 {
                            let converted = UInt64(exactly: (deadlineSeconds * 1_000_000_000).rounded()) ?? UInt64.max
                            // Clamp to `(UInt64.max / 2)` to work around a bug in older versions of `Task.sleep`. (https://github.com/swiftlang/swift/issues/80791)
                            let deadlineNanoseconds = min(converted, UInt64.max / 2)
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

    private func withOptionalBufferedWriter<T>(forWritingAt path: FilePath?, body: (inout BufferedWriter<WriteFileHandle>?) async throws -> T) async throws -> T {
        guard let path = path else {
            var writer: BufferedWriter<WriteFileHandle>? = nil
            return try await body(&writer)
        }
        return try await FileSystem.shared.withFileHandle(forWritingAt: path, options: OpenOptions.Write.newFile(replaceExisting: false)) { fileHandle in
            try await fileHandle.withBufferedWriter { writer in
                var maybeWriter: BufferedWriter<WriteFileHandle>? = writer
                defer { if let finalWriter = maybeWriter { writer = finalWriter } }
                return try await body(&maybeWriter)
            }
        }
    }

    /// No cleanup has to be done, so this isn't a `withStreamingWriter` function.
    private func makeStreamingWriter(channel: String?, _ ctx: Context) -> ((ByteBuffer) async throws -> Void) {
        guard let streamingLogHandler = ctx.streamingLogHandler, let channel = channel else {
            return { _ in () }
        }
        return { try await streamingLogHandler.streamLog(channel: channel, $0) }
    }

    private enum OutputSource {
        case stdout
        case stderr
    }

    private func handleOutputs<S: AsyncSequence>(_ taggedOutputs: S, stdoutPath: FilePath?, stderrPath: FilePath?, _ ctx: Context) async throws where S.Element == (ByteBuffer, OutputSource) {
        let areLocalOutputsMerged = stdoutPath == stderrPath

        let stdoutStreamer = makeStreamingWriter(channel: stdoutStreamingDestination, ctx)
        let stderrStreamer = makeStreamingWriter(channel: stderrStreamingDestination, ctx)
        try await withOptionalBufferedWriter(forWritingAt: stdoutPath) { stdoutWriter in
            // If local stdout and stderr are being written to the same file, only open one writer.
            try await withOptionalBufferedWriter(forWritingAt: areLocalOutputsMerged ? nil : stderrPath) { stderrWriter in
                for try await (chunk, source) in taggedOutputs {
                    switch source {
                    case .stdout:
                        async let localWriteResult = stdoutWriter?.write(contentsOf: chunk)
                        async let streamingWriteResult: () = stdoutStreamer(chunk)
                        _ = try await (localWriteResult, streamingWriteResult)
                    case .stderr:
                        // I wish Swift let you make references to structs; that would make this a lot cleaner/simpler.
                        async let localWriteResult = (areLocalOutputsMerged ? stdoutWriter?.write(contentsOf: chunk) : stderrWriter?.write(contentsOf: chunk))
                        async let streamingWriteResult: () = stderrStreamer(chunk)
                        _ = try await (localWriteResult, streamingWriteResult)
                    }
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
    public let inputTree: ProcessInputTreeID

    public let spec: ProcessSpec

    public let initialOutputTree: ProcessOutputTreeID?

    public init(
        inputTree: ProcessInputTreeID,
        spec: ProcessSpec,
        initialOutputTree: ProcessOutputTreeID? = nil
    ) {
        self.inputTree = inputTree
        self.spec = spec
        self.initialOutputTree = initialOutputTree
    }

    public enum FXSpawnError: Error {
        case failure(outputTree: LLBDataID, underlyingError: Error)
        case recoveryUploadFailure(uploadError: Error, originalError: Error)
    }

    public func run(_ ctx: Context) async throws -> SpawnProcessResult {
        try await withTemporaryDirectory(dir: self.spec.temporaryDirectoryBase, ctx) { tmpDir in
            try await withTemporaryDirectory(dir: self.spec.temporaryDirectoryBase, ctx) { outputPath in
                return try await run(outputPath: outputPath, tmpDir: tmpDir, ctx)
            }
        }
    }

    private func run(outputPath: AbsolutePath, tmpDir: AbsolutePath, _ ctx: Context) async throws -> SpawnProcessResult {
        try await inputTree.materialize(ctx) { inputPath in
            if let initialOutputTree = initialOutputTree {
                try await LLBCASFileTree.export(initialOutputTree.dataID, from: ctx.db, to: outputPath, stats: LLBCASFileTree.ExportProgressStatsInt64(), ctx).get()
            }

            do {
                let exitCode = try await spec.process(inputPath: inputPath, outputPath: outputPath, tmpDir: tmpDir, ctx).asShellExitCode
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

extension ProcessSpec.SpawnOptions {
    func toProcessExecutorSpawnOptions(
        _ runtimeValueMapper: (ProcessSpec.RuntimeValue) -> String
    ) -> ProcessExecutor.SpawnOptions {
        var result = ProcessExecutor.SpawnOptions.default

        if let changedWorkingDirectory {
            result.changedWorkingDirectory = runtimeValueMapper(changedWorkingDirectory)
        }

        return result
    }
}
