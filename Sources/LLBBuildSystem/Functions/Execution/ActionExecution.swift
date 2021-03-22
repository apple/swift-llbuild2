// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import SwiftProtobuf
import TSFCASFileTree

extension LLBActionExecutionKey: LLBBuildKey {}
extension LLBActionExecutionValue: LLBBuildValue {}

/// Convenience initializer.
public extension LLBActionExecutionKey {

    static func command(
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        inputs: [LLBActionInput],
        outputs: [LLBActionOutput],
        chainedLogsID: LLBDataID? = nil,
        unconditionalOutputs: [LLBActionOutput] = [],
        mnemonic: String = "",
        description: String = "",
        dynamicIdentifier: LLBDynamicActionIdentifier? = nil,
        cacheableFailure: Bool = false
    ) -> Self {
        return LLBActionExecutionKey.with {
            $0.actionExecutionType = .command(LLBCommandActionExecution.with {
                $0.actionSpec = LLBActionSpec(
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    preActions: []
                )
                $0.inputs = inputs
                $0.outputs = outputs
                $0.unconditionalOutputs = unconditionalOutputs
                if let dynamicIdentifier = dynamicIdentifier {
                    $0.dynamicIdentifier = dynamicIdentifier
                }
                $0.mnemonic = mnemonic
                $0.description_p = description
                $0.cacheableFailure = cacheableFailure
            })
            if let chainedLogsID = chainedLogsID {
                $0.chainedLogsID = chainedLogsID
            }
        }
    }

    static func command(
        actionSpec: LLBActionSpec,
        inputs: [LLBActionInput],
        outputs: [LLBActionOutput],
        chainedLogsID: LLBDataID? = nil,
        unconditionalOutputs: [LLBActionOutput] = [],
        mnemonic: String,
        description: String,
        dynamicIdentifier: LLBDynamicActionIdentifier? = nil,
        cacheableFailure: Bool = false,
        label: LLBLabel? = nil
    ) -> Self {
        return LLBActionExecutionKey.with {
            $0.actionExecutionType = .command(LLBCommandActionExecution.with {
                $0.actionSpec = actionSpec
                $0.inputs = inputs
                $0.outputs = outputs
                $0.unconditionalOutputs = unconditionalOutputs
                if let dynamicIdentifier = dynamicIdentifier {
                    $0.dynamicIdentifier = dynamicIdentifier
                }
                $0.mnemonic = mnemonic
                $0.description_p = description
                $0.cacheableFailure = cacheableFailure
                if let label = label {
                    $0.label = label
                }
            })
            if let chainedLogsID = chainedLogsID {
                $0.chainedLogsID = chainedLogsID
            }
        }
    }

    static func mergeTrees(inputs: [LLBActionInput], chainedLogsID: LLBDataID? = nil) -> Self {
        return LLBActionExecutionKey.with {
            $0.actionExecutionType = .mergeTrees(LLBMergeTreesActionExecution.with {
                $0.inputs = inputs
            })
            if let chainedLogsID = chainedLogsID {
                $0.chainedLogsID = chainedLogsID
            }
        }
    }

    var inputs: [LLBActionInput] {
        switch actionExecutionType {
        case .command(let commandKey):
            return commandKey.inputs
        case .mergeTrees(let mergeKey):
            return mergeKey.inputs
        default:
            return []
        }
    }
}

extension LLBPreActionSpec: LLBBuildEventPreAction {}

extension LLBActionExecutionKey: LLBBuildEventActionDescription {
    public var arguments: [String] {
        command.actionSpec.arguments
    }

    public var environment: [String : String] {
        command.actionSpec.environment.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    public var preActions: [LLBBuildEventPreAction] {
        self.command.actionSpec.preActions
    }

    public var mnemonic: String {
        command.mnemonic
    }

    public var description: String {
        command.description_p
    }

    public var owner: LLBLabel? {
        if command.hasLabel {
            return command.label
        }
        return nil
    }
}

/// Convenience initializer.
fileprivate extension LLBActionExecutionValue {
    init(outputs: [LLBDataID], stdoutID: LLBDataID? = nil, stderrID: LLBDataID? = nil) {
        self.outputs = outputs
        if let stdoutID = stdoutID {
            self.stdoutID = stdoutID
        }
    }

    init(from executionResponse: LLBActionExecutionResponse) {
        self.outputs = executionResponse.outputs
        self.unconditionalOutputs = executionResponse.unconditionalOutputs
        self.stdoutID = executionResponse.stdoutID
    }

    static func cachedFailure(stdoutID: LLBDataID, unconditionalOutputs: [LLBDataID]) -> LLBActionExecutionValue {
        return LLBActionExecutionValue.with {
            $0.cachedFailure = true
            $0.stdoutID = stdoutID
            $0.unconditionalOutputs = unconditionalOutputs
        }
    }
}

public enum LLBActionExecutionError: Error {
    /// Error for invalid action execution key.
    case invalid

    /// Error related to the scheduling of an action.
    case executorError(Error)

    /// Error related to an actual action (i.e. action completed but did not finish successfully).
    case actionExecutionError(stdoutID: LLBDataID, unconditionalOutputs: [LLBDataID])

    /// Error thrown when given input types are not of the declared type.
    case invalidInput(String)
}

final class ActionExecutionFunction: LLBBuildFunction<LLBActionExecutionKey, LLBActionExecutionValue> {
    let dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?

    init(dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?) {
        self.dynamicActionExecutorDelegate = dynamicActionExecutorDelegate
    }

    override func evaluate(
        key actionExecutionKey: LLBActionExecutionKey,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionExecutionValue> {
        return validateInputs(actionExecutionKey.inputs, ctx).flatMap {
            let chainedLogsID: LLBDataID?
            if actionExecutionKey.hasChainedLogsID {
                chainedLogsID = actionExecutionKey.chainedLogsID
            } else {
                chainedLogsID = nil
            }

            switch actionExecutionKey.actionExecutionType {
            case let .command(commandKey):
                ctx.buildEventDelegate?.actionExecutionStarted(action: actionExecutionKey)
                let requestExtras = LLBActionExecutionRequestExtras(
                    mnemonic: actionExecutionKey.mnemonic,
                    description: actionExecutionKey.description,
                    owner: actionExecutionKey.owner
                )
                return self.evaluateCommand(
                    commandKey: commandKey,
                    chainedLogsID: chainedLogsID,
                    requestExtras: requestExtras,
                    fi,
                    ctx
                ).map {
                    ctx.buildEventDelegate?.actionExecutionCompleted(action: actionExecutionKey)
                    return $0
                }.flatMapErrorThrowing { error in
                    ctx.buildEventDelegate?.actionExecutionCompleted(action: actionExecutionKey)
                    throw error
                }
            case let .mergeTrees(mergeTreesKey):
                return self.evaluateMergeTrees(mergeTreesKey: mergeTreesKey, chainedLogsID: chainedLogsID, fi, ctx)
            case .none:
                return ctx.group.next().makeFailedFuture(LLBActionExecutionError.invalid)
            }
        }
    }

    private func validateInputs(_ inputs: [LLBActionInput], _ ctx: Context) -> LLBFuture<Void> {
        let client = LLBCASFSClient(ctx.db)

        let validationFutures = inputs.map { input in
            client.load(input.dataID, ctx).flatMapThrowing { node in
                switch input.type {
                case .directory:
                    if node.type() != .directory {
                        throw LLBActionExecutionError.invalidInput("Expected a tree but got a non tree data ID")
                    }
                case .file:
                    if node.type() == .directory {
                        throw LLBActionExecutionError.invalidInput("Expected a file but got a tree data ID")
                    }
                case .UNRECOGNIZED(let value):
                    throw LLBActionExecutionError.invalidInput("Unrecognized input type: \(value)")
                }
            }.flatMapErrorThrowing { error in
                if case .noEntry = error as? LLBCASFSClient.Error {
                    throw LLBActionExecutionError.invalidInput(
                        "Missing input \(input.path) \(input.dataID.debugDescription)"
                    )
                }
                throw error
            }
        }

        return LLBFuture.whenAllSucceed(validationFutures, on: ctx.group.next()).map { _ in }
    }

    private func evaluateCommand(
        commandKey: LLBCommandActionExecution,
        chainedLogsID: LLBDataID?,
        requestExtras: LLBActionExecutionRequestExtras,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionExecutionValue> {
        let additionalRequestData: [Google_Protobuf_Any]
        if let requestExtrasAny = try? Google_Protobuf_Any(message: requestExtras) {
            additionalRequestData = [requestExtrasAny]
        } else {
            additionalRequestData = []
        }

        let actionExecutionRequest = LLBActionExecutionRequest(
            actionSpec: commandKey.actionSpec,
            inputs: commandKey.inputs,
            outputs: commandKey.outputs,
            unconditionalOutputs: commandKey.unconditionalOutputs,
            additionalData: additionalRequestData,
            baseLogsID: chainedLogsID
        )

        let resultFuture: LLBFuture<LLBActionExecutionResponse>
        if commandKey.dynamicIdentifier.isEmpty {
            resultFuture = fi.spawn(actionExecutionRequest, ctx)
        } else if let dynamicExecutor = dynamicActionExecutorDelegate?.dynamicActionExecutor(for: commandKey.dynamicIdentifier) {
            resultFuture = dynamicExecutor.execute(request: actionExecutionRequest, fi, ctx)

        } else {
            resultFuture = ctx.group.next().makeFailedFuture(LLBActionExecutionError.invalid)
        }

        return resultFuture.flatMapErrorThrowing { error in
            // Action failures do not throw from the executor, so this must be an executor specific error.
            throw LLBActionExecutionError.executorError(error)
        }.flatMapThrowing { executionResponse in
            // If the action failed, convert it into an actual error with the dataIDs of the output logs.
            if executionResponse.exitCode != 0 {
                if commandKey.cacheableFailure {
                    return LLBActionExecutionValue.cachedFailure(
                        stdoutID: executionResponse.stdoutID,
                        unconditionalOutputs: executionResponse.unconditionalOutputs
                    )
                } else {
                    throw LLBActionExecutionError.actionExecutionError(
                        stdoutID: executionResponse.stdoutID,
                        unconditionalOutputs: executionResponse.unconditionalOutputs
                    )
                }
            }

            return LLBActionExecutionValue(from: executionResponse)
        }
    }

    private func evaluateMergeTrees(
        mergeTreesKey: LLBMergeTreesActionExecution,
        chainedLogsID: LLBDataID?,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionExecutionValue> {
        let inputs = mergeTreesKey.inputs
        // Skip merging if there's a single tree as input, with no path to prepend.
        if inputs.count == 1, inputs[0].type == .directory, inputs[0].path.isEmpty {
            return ctx.group.next().makeSucceededFuture(
                LLBActionExecutionValue(outputs: [inputs[0].dataID], stdoutID: chainedLogsID, stderrID: chainedLogsID)
            )
        }

        let client = LLBCASFSClient(ctx.db)

        var prependedTrees = [LLBFuture<LLBCASFileTree>]()

        for input in inputs {
            prependedTrees.append(client.wrap(input.dataID, path: input.path, ctx))
        }

        // Skip merging if there is a single prepended tree.
        if prependedTrees.count == 1 {
            return prependedTrees[0].map {
                LLBActionExecutionValue(outputs: [$0.id], stdoutID: chainedLogsID, stderrID: chainedLogsID)
            }
        }

        return LLBFuture.whenAllSucceed(prependedTrees, on: ctx.group.next()).flatMap { trees in
            return LLBCASFileTree.merge(trees: trees, in: ctx.db, ctx)
        }.map {
            return LLBActionExecutionValue(outputs: [$0.id], stdoutID: chainedLogsID, stderrID: chainedLogsID)
        }
    }
}
