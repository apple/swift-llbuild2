// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import TSCBasic
import TSCUtility
import TSFCAS
import TSFCASFileTree
import TSFFutures

extension Foundation.Process {
    private enum ProcessTerminationError: Error {
        case signaled(Int32)
        case unknown(Int32)
        case notStarted
        case notFinished
    }

    private struct ProcessKiller: LLBCancelProtocol {
        private let runningProcess: Foundation.Process
        init(runningProcess: Foundation.Process) {
            self.runningProcess = runningProcess
        }

        func cancel(reason: String?) {
            let pid = runningProcess.processIdentifier
            kill(pid, SIGKILL)
        }
    }

    fileprivate func runCancellable(_ ctx: Context) -> LLBCancellableFuture<Int32> {
        let completionPromise: LLBPromise<Int32> = ctx.group.next().makePromise()

        self.terminationHandler = { process in
            ctx.logger?.debug("Process terminated: \(process)")

            guard process.processIdentifier > 0 else {
                completionPromise.fail(ProcessTerminationError.notStarted)
                return
            }

            guard !process.isRunning else {
                completionPromise.fail(ProcessTerminationError.notFinished)
                return
            }

            let status = process.terminationStatus

            switch process.terminationReason {
            case .exit:
                completionPromise.succeed(status)
            case .uncaughtSignal:
                completionPromise.fail(ProcessTerminationError.signaled(status))
            @unknown default:
                completionPromise.fail(ProcessTerminationError.unknown(status))
            }
        }

        do {
            ctx.logger?.debug("Will start running process: \(self)")
            try run()
            ctx.logger?.trace("Did start running process: \(self)")
        } catch {
            completionPromise.fail(error)
        }

        let canceller = LLBCanceller(ProcessKiller(runningProcess: self))

        return LLBCancellableFuture(completionPromise.futureResult, canceller: canceller)
    }
}

public struct ProcessSpec: Codable {
    public enum Executable: Codable {
        case absolutePath(AbsolutePath)
        case inputPath(RelativePath)

        #if swift(<5.5)
        enum CodingKeys: CodingKey {
            case absolutePath
            case inputPath
        }

        enum AbsolutePathCodingKeys: CodingKey {
            case _0
        }

        enum InputPathCodingKeys: CodingKey {
            case _0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .absolutePath(value):
                var nestedContainer = container.nestedContainer(
                    keyedBy: AbsolutePathCodingKeys.self, forKey: .absolutePath)
                try nestedContainer.encode(value, forKey: ._0)
            case let .inputPath(value):
                var nestedContainer = container.nestedContainer(keyedBy: InputPathCodingKeys.self, forKey: .inputPath)
                try nestedContainer.encode(value, forKey: ._0)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.allKeys.count != 1 {
                let context = DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid number of keys found, expected one.")
                throw DecodingError.typeMismatch(Executable.self, context)
            }

            switch container.allKeys.first.unsafelyUnwrapped {
            case .absolutePath:
                let nestedContainer = try container.nestedContainer(
                    keyedBy: AbsolutePathCodingKeys.self, forKey: .absolutePath)
                self = .absolutePath(try nestedContainer.decode(AbsolutePath.self, forKey: ._0))
            case .inputPath:
                let nestedContainer = try container.nestedContainer(
                    keyedBy: InputPathCodingKeys.self, forKey: .inputPath)
                self = .inputPath(try nestedContainer.decode(RelativePath.self, forKey: ._0))
            }
        }
        #endif
    }

    public enum RuntimeValue: Codable {
        case literal(String)
        case inputPath(RelativePath)
        case outputPath(RelativePath)

        #if swift(<5.5)
        enum CodingKeys: CodingKey {
            case literal
            case inputPath
            case outputPath
        }

        enum LiteralCodingKeys: CodingKey {
            case _0
        }

        enum InputPathCodingKeys: CodingKey {
            case _0
        }

        enum OutputPathCodingKeys: CodingKey {
            case _0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .literal(value):
                var nestedContainer = container.nestedContainer(keyedBy: LiteralCodingKeys.self, forKey: .literal)
                try nestedContainer.encode(value, forKey: ._0)
            case let .inputPath(value):
                var nestedContainer = container.nestedContainer(keyedBy: InputPathCodingKeys.self, forKey: .inputPath)
                try nestedContainer.encode(value, forKey: ._0)
            case let .outputPath(value):
                var nestedContainer = container.nestedContainer(keyedBy: OutputPathCodingKeys.self, forKey: .outputPath)
                try nestedContainer.encode(value, forKey: ._0)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.allKeys.count != 1 {
                let context = DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid number of keys found, expected one.")
                throw DecodingError.typeMismatch(RuntimeValue.self, context)
            }

            switch container.allKeys.first.unsafelyUnwrapped {
            case .literal:
                let nestedContainer = try container.nestedContainer(keyedBy: LiteralCodingKeys.self, forKey: .literal)
                self = .literal(try nestedContainer.decode(String.self, forKey: ._0))
            case .inputPath:
                let nestedContainer = try container.nestedContainer(
                    keyedBy: InputPathCodingKeys.self, forKey: .inputPath)
                self = .inputPath(try nestedContainer.decode(RelativePath.self, forKey: ._0))
            case .outputPath:
                let nestedContainer = try container.nestedContainer(
                    keyedBy: OutputPathCodingKeys.self, forKey: .outputPath)
                self = .outputPath(try nestedContainer.decode(RelativePath.self, forKey: ._0))
            }
        }
        #endif
    }

    let executable: Executable
    let arguments: [RuntimeValue]
    let environment: [String: RuntimeValue]

    let stdinSource: RelativePath?
    let stdoutDestination: RelativePath?
    let stderrDestination: RelativePath?

    public init(
        executable: Executable,
        arguments: [RuntimeValue] = [],
        environment: [String: RuntimeValue] = [:],
        stdinSource: RelativePath? = nil,
        stdoutDestination: RelativePath? = nil,
        stderrDestination: RelativePath? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdinSource = stdinSource
        self.stdoutDestination = stdoutDestination
        self.stderrDestination = stderrDestination
    }

    enum ProcessSpecError: Error {
        case unableToCreateFile(RelativePath)
        case unableToCreateFileHandle(RelativePath)
    }

    fileprivate func process(inputPath: AbsolutePath, outputPath: AbsolutePath) throws -> Foundation.Process {
        let runtimeValueMapper: (RuntimeValue) -> String = { value in
            switch value {
            case .literal(let v):
                return v
            case .inputPath(let path):
                return inputPath.appending(path).pathString
            case .outputPath(let path):
                return outputPath.appending(path).pathString
            }
        }

        let exePath: AbsolutePath
        switch executable {
        case .absolutePath(let path):
            exePath = path
        case .inputPath(let path):
            exePath = inputPath.appending(path)
        }

        let process = Process()

        process.executableURL = URL(fileURLWithPath: exePath.pathString)
        process.arguments = arguments.map(runtimeValueMapper)
        process.environment = environment.mapValues(runtimeValueMapper)

        let devNull = "/dev/null"

        if let stdin = stdinSource {
            let path = inputPath.appending(stdin).pathString

            guard let standardInput = FileHandle(forReadingAtPath: path) else {
                throw ProcessSpecError.unableToCreateFileHandle(stdin)
            }

            process.standardInput = standardInput
        } else {
            process.standardInput = FileHandle(forReadingAtPath: devNull)
        }

        let fileManager = FileManager()

        func outputFileHandle(for destination: RelativePath?) throws -> FileHandle? {
            guard let destination = destination else {
                return FileHandle(forWritingAtPath: devNull)
            }

            let path = outputPath.appending(destination).pathString

            guard fileManager.createFile(atPath: path, contents: nil) else {
                throw ProcessSpecError.unableToCreateFile(destination)
            }

            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw ProcessSpecError.unableToCreateFileHandle(destination)
            }

            return handle
        }

        if stdoutDestination == stderrDestination {
            let handle = try outputFileHandle(for: stdoutDestination)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = try outputFileHandle(for: stdoutDestination)
            process.standardError = try outputFileHandle(for: stderrDestination)
        }

        return process
    }
}

struct ProcessInputTree: FXTreeID {
    let dataID: LLBDataID
}

extension SpawnProcess: FXAction {
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

    public func run(_ ctx: Context) -> LLBFuture<SpawnProcessResult> {
        inputTree.materialize(ctx) { inputPath in
            withTemporaryDirectory(ctx) { outputPath in
                let export: LLBFuture<Void>
                if let initialOutputTree = initialOutputTree {
                    export = LLBCASFileTree.export(initialOutputTree.dataID, from: ctx.db, to: outputPath, ctx)
                } else {
                    export = ctx.group.next().makeSucceededFuture(())
                }

                return export.flatMap { _ in
                    do {
                        let process = try spec.process(inputPath: inputPath, outputPath: outputPath)
                        let cancellable = process.runCancellable(ctx)

                        ctx.fxApplyDeadline(cancellable)

                        return cancellable.future.flatMap { exitCode in
                            LLBCASFileTree.import(path: outputPath, to: ctx.db, ctx).map { treeID in
                                SpawnProcessResult(treeID: .init(dataID: treeID), exitCode: exitCode)
                            }
                        }.flatMapError { error in
                            return LLBCASFileTree.import(path: outputPath, to: ctx.db, ctx).flatMapErrorThrowing { uploadError in
                                throw FXSpawnError.recoveryUploadFailure(uploadError: uploadError, originalError: error)
                            }.flatMapThrowing { treeID in
                                throw FXSpawnError.failure(outputTree: treeID, underlyingError: error)
                            }
                        }
                    } catch {
                        return ctx.group.next().makeFailedFuture(error)
                    }
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
