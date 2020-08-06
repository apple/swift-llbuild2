// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import SwiftProtobuf

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
                if let dynamicIdentifier = dynamicIdentifier {
                    $0.dynamicIdentifier = dynamicIdentifier
                }
                $0.mnemonic = mnemonic
                $0.description_p = description
                $0.cacheableFailure = cacheableFailure
            })
        }
    }

    static func command(
        actionSpec: LLBActionSpec,
        inputs: [LLBActionInput],
        outputs: [LLBActionOutput],
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
        }
    }

    static func mergeTrees(inputs: [LLBActionInput]) -> Self {
        return LLBActionExecutionKey.with {
            $0.actionExecutionType = .mergeTrees(LLBMergeTreesActionExecution.with {
                $0.inputs = inputs
            })
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
        if let stderrID = stderrID {
            self.stderrID = stderrID
        }
    }

    init(from executionResponse: LLBActionExecutionResponse) {
        self.outputs = executionResponse.outputs
        self.stdoutID = executionResponse.stdoutID
        self.stderrID = executionResponse.stderrID
    }

    static func cachedFailure(stdoutID: LLBDataID, stderrID: LLBDataID) -> LLBActionExecutionValue {
        return LLBActionExecutionValue.with {
            $0.cachedFailure = true
            $0.stdoutID = stdoutID
            $0.stderrID = stderrID
        }
    }
}

public enum LLBActionExecutionError: Error {
    /// Error for invalid action execution key.
    case invalid

    /// Error related to the scheduling of an action.
    case executorError(Error)

    /// Error related to an actual action (i.e. action completed but did not finish successfully).
    case actionExecutionError(LLBDataID, LLBDataID)
}

final class ActionExecutionFunction: LLBBuildFunction<LLBActionExecutionKey, LLBActionExecutionValue> {
    let dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?

    init(dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?) {
        self.dynamicActionExecutorDelegate = dynamicActionExecutorDelegate
    }

    override func evaluate(key actionExecutionKey: LLBActionExecutionKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBActionExecutionValue> {

        switch actionExecutionKey.actionExecutionType {
        case let .command(commandKey):
            ctx.buildEventDelegate?.actionExecutionStarted(action: actionExecutionKey)
            return evaluateCommand(commandKey: commandKey, fi, ctx).map {
                ctx.buildEventDelegate?.actionExecutionCompleted(action: actionExecutionKey)
                return $0
            }.flatMapErrorThrowing { error in
                ctx.buildEventDelegate?.actionExecutionCompleted(action: actionExecutionKey)
                throw error
            }
        case let .mergeTrees(mergeTreesKey):
            return evaluateMergeTrees(mergeTreesKey: mergeTreesKey, fi, ctx)
        case .none:
            return ctx.group.next().makeFailedFuture(LLBActionExecutionError.invalid)
        }
    }

    private func evaluateCommand(commandKey: LLBCommandActionExecution, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBActionExecutionValue> {
        let additionalRequestData: [Google_Protobuf_Any]
        if commandKey.hasLabel, let labelAny = try? Google_Protobuf_Any(message: commandKey.label) {
            additionalRequestData = [labelAny]
        } else {
            additionalRequestData = []
        }

        let actionExecutionRequest = LLBActionExecutionRequest(
            actionSpec: commandKey.actionSpec,
            inputs: commandKey.inputs,
            outputs: commandKey.outputs,
            additionalData: additionalRequestData
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
                        stderrID: executionResponse.stderrID
                    )
                } else {
                    throw LLBActionExecutionError.actionExecutionError(
                        executionResponse.stdoutID,
                        executionResponse.stderrID
                    )
                }
            }

            return LLBActionExecutionValue(from: executionResponse)
        }
    }

    private func evaluateMergeTrees(mergeTreesKey: LLBMergeTreesActionExecution, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBActionExecutionValue> {
        let inputs = mergeTreesKey.inputs
        // Skip merging if there's a single tree as input, with no path to prepend.
        if inputs.count == 1, inputs[0].type == .directory, inputs[0].path.isEmpty {
            return ctx.group.next().makeSucceededFuture(LLBActionExecutionValue(outputs: [inputs[0].dataID], stdoutID: nil, stderrID: nil))
        }

        let client = LLBCASFSClient(ctx.db)

        var prependedTrees = [LLBFuture<LLBCASFileTree>]()

        for input in inputs {
            prependedTrees.append(client.wrap(input.dataID, path: input.path, ctx))
        }

        // Skip merging if there is a single prepended tree.
        if prependedTrees.count == 1 {
            return prependedTrees[0].map { LLBActionExecutionValue(outputs: [$0.id], stdoutID: nil, stderrID: nil) }
        }

        return LLBFuture.whenAllSucceed(prependedTrees, on: ctx.group.next()).flatMap { trees in
            return LLBCASFileTree.merge(trees: trees, in: ctx.db, ctx)
        }.map {
            return LLBActionExecutionValue(outputs: [$0.id])
        }
    }
}
