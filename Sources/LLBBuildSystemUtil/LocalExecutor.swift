// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import llbuild2
import TSCBasic
import Dispatch

public enum LLBLocalExecutorError: Error {
    case unimplemented(String)
    case unexpected(Error)
    case missingInput(LLBActionInput)
    case preActionFailure(String)
}

public protocol LLBLocalExecutorDelegate {
    func launchingProcess(arguments: [String], workingDir: AbsolutePath, environment: [String: String])
    func finishedProcess(with result: ProcessResult)
}

public protocol LLBLocalExecutorStatsObserver: AnyObject {
    func startObserving(_ stats: LLBCASFileTree.ImportProgressStats)
    func stopObserving(_ stats: LLBCASFileTree.ImportProgressStats)

    func startObserving(_ stats: LLBCASFileTree.ExportProgressStats)
    func stopObserving(_ stats: LLBCASFileTree.ExportProgressStats)
}

/// Simple local executor that uses the host machine's resources to execute actions.
final public class LLBLocalExecutor: LLBExecutor {
    let outputBase: AbsolutePath
    let delegateCallbackQueue: DispatchQueue = DispatchQueue(label: "org.swift.llbuild2-\(LLBLocalExecutor.self)-delegate")
    let delegate: LLBLocalExecutorDelegate?
    weak var statsObserver: LLBLocalExecutorStatsObserver?

    public init(
        outputBase: AbsolutePath,
        delegate: LLBLocalExecutorDelegate? = nil,
        statsObserver: LLBLocalExecutorStatsObserver? = nil
    ) {
        self.outputBase = outputBase
        self.delegate = delegate
        self.statsObserver = statsObserver
    }

    public func execute(request: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        var inputFutures = [LLBFuture<Void>]()
        let client = LLBCASFSClient(ctx.db)

        for input in request.inputs {
            // Create the parent directory for each of the inputs, so that they can be exported there.
            let fullInputPath = outputBase.appending(RelativePath(input.path))
            do {
                try localFileSystem.createDirectory(fullInputPath.parentDirectory, recursive: true)
            } catch {
                return ctx.group.next().makeFailedFuture(error)
            }

            // This is a local optimization, if the file has already been exported, don't export it again. Because
            // we're not supporting incremental builds locally (by creating a new output base for each invocation) we're
            // not running a risk of the files having other contents. This assumes that the paths for all artifacts
            // in a build are unique, i.e. there are no 2 artifacts that share the same path.
            if !localFileSystem.exists(fullInputPath) {
                if input.type == .directory {
                    let stats = LLBCASFileTree.ExportProgressStats()
                    statsObserver?.startObserving(stats)
                    inputFutures.append(
                        LLBCASFileTree.export(
                            input.dataID,
                            from: ctx.db,
                            to: .init(fullInputPath.pathString),
                            ctx
                        ).always { _ in
                            self.statsObserver?.stopObserving(stats)
                        }
                    )
                } else {
                    inputFutures.append(
                        client.load(input.dataID, ctx).flatMap { (node: LLBCASFSNode) -> LLBFuture<(LLBByteBufferView, LLBFileType)> in
                            guard let blob = node.blob else {
                                return ctx.group.next().makeFailedFuture(LLBLocalExecutorError.missingInput(input))
                            }
                            return blob.read(ctx).map { ($0, node.type()) }
                        }.flatMapThrowing { (data, type) in
                            try localFileSystem.writeFileContents(fullInputPath, bytes: ByteString(data))
                            if type == .executable {
                                try localFileSystem.chmod(.executable, path: fullInputPath)
                            }
                        }
                    )
                }
            }
        }

        return LLBFuture.whenAllSucceed(inputFutures, on: ctx.group.next()).flatMapThrowing { _ in
            // For each of the declared outputs, make sure that the parent directory exists.
            for output in request.outputs {
                try localFileSystem.createDirectory(
                    self.outputBase.appending(RelativePath(output.path)).parentDirectory,
                    recursive: true
                )
            }
        }.flatMapThrowing { _ -> TSCBasic.Process in
            let environment = request.actionSpec.environment.reduce(into: [String: String]()) { (dict, pair) in
                dict[pair.name] = pair.value
            }

            // Execute the pre-actions of the request.
            for preActionSpec in request.actionSpec.preActions {
                let preActionEnvironment = preActionSpec.environment.reduce(into: environment) { (dict, pair) in
                    dict[pair.name] = pair.value
                }

                let preActionProcess = TSCBasic.Process(
                    arguments: preActionSpec.arguments,
                    environment: preActionEnvironment,
                    workingDirectory: self.outputBase.appending(RelativePath(request.actionSpec.workingDirectory)),
                    outputRedirection: .collect,
                    startNewProcessGroup: false
                )

                try preActionProcess.launch()

                if preActionSpec.background {
                    throw LLBLocalExecutorError.unimplemented("preAction background mode is not yet implemented.")
                } else {
                    // If the pre-action is not in background mode, wait until it finishes.
                    let result = try preActionProcess.waitUntilExit()
                    guard case .terminated(code: let code) = result.exitStatus, code == 0 else {
                        throw LLBLocalExecutorError.preActionFailure(try result.utf8stderrOutput())
                    }
                }
            }

            // Execute the main action of the request.
            let arguments = request.actionSpec.arguments
            let workingDir = self.outputBase.appending(RelativePath(request.actionSpec.workingDirectory))
            let process = TSCBasic.Process(
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDir,
                outputRedirection: .collect(redirectStderr: true),
                startNewProcessGroup: false
            )

            self.delegateCallbackQueue.async {
                self.delegate?.launchingProcess(arguments: arguments, workingDir: workingDir, environment: environment)
            }

            try process.launch()
            return process
        }.flatMapBlocking(onto: DispatchQueue.global()) { process in
            try process.waitUntilExit()
        }.flatMapThrowing { result -> (Int, [UInt8]) in
            self.delegateCallbackQueue.async {
                self.delegate?.finishedProcess(with: result)
            }

            let resultExitCode: Int
            switch result.exitStatus {
            case .terminated(let code):
                resultExitCode = Int(code)
            case .signalled(_):
                resultExitCode = -1
            }

            return (resultExitCode, try result.output.get())
        }.flatMap { (exitCode, stdout) in
            // Upload the stdout and stderr of the action into the CAS.
            let baseLogContents: LLBFuture<ArraySlice<UInt8>>
            if request.hasBaseLogsID {
                baseLogContents = ctx.db.get(request.baseLogsID, ctx).flatMapThrowing { object -> ArraySlice<UInt8> in
                    if let object = object {
                        return ArraySlice(object.data.readableBytesView)
                    } else {
                        throw StringError("No logs available for base")
                    }
                }
            } else {
                baseLogContents = ctx.group.next().makeSucceededFuture([])
            }

            let stdoutFuture = baseLogContents.flatMap { baseLogs in
                ctx.db.put(data: .withBytes(baseLogs + stdout[...]), ctx)
            }

            let outputFutures: [LLBFuture<LLBDataID>]

            // Only upload outputs if the action exited successfully.
            if exitCode == 0 {
                outputFutures = request.outputs.map { self.importOutput(output: $0, ctx) }
            } else {
                outputFutures = []
            }

            let outputsFuture = LLBFuture.whenAllSucceed(outputFutures, on: ctx.group.next())

            let unconditionalOutputFutures = request.unconditionalOutputs.map {
                self.importOutput(output: $0, allowNonExistentFiles: true, ctx)
            }
            let unconditionalOutputsFuture = LLBFuture.whenAllSucceed(unconditionalOutputFutures, on: ctx.group.next())

            return outputsFuture.and(unconditionalOutputsFuture).and(stdoutFuture).map { outputs, stdoutID in
                return LLBActionExecutionResponse(
                    outputs: outputs.0,
                    unconditionalOutputs: outputs.1,
                    exitCode: exitCode,
                    stdoutID: stdoutID
                )
            }
        }.flatMapErrorThrowing { error in
            // If we found any errors that were not LLBExecutorError, convert them into an LLBExecutorError.
            if error is LLBLocalExecutorError {
                throw error
            }
            throw LLBLocalExecutorError.unexpected(error)
        }
    }

    func importOutput(output: LLBActionOutput, allowNonExistentFiles: Bool = false, _ ctx: Context) -> LLBFuture<LLBDataID> {
        let outputPath = self.outputBase.appending(RelativePath(output.path))
        let stats = LLBCASFileTree.ImportProgressStats()
        statsObserver?.startObserving(stats)
        return LLBCASFileTree.import(path: outputPath, to: ctx.db, stats: stats, ctx).flatMapError { error in
            if let fsError = error as? FileSystemError, fsError.kind == .noEntry {
                if output.type == .directory {
                    // If we didn't find an output artifact that was a directory, create an empty CASTree to
                    // represent it.
                    return LLBCASFileTree.create(files: [], in: ctx.db, ctx).map { $0.id }
                } else if output.type == .file, allowNonExistentFiles {
                    return ctx.db.put(data: .init(bytes: []), ctx)
                }
            }

            return ctx.group.next().makeFailedFuture(error)
        }.always { _ in
            self.statsObserver?.stopObserving(stats)
        }
    }
}
