// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBCAS
import LLBBuildSystemProtocol

extension ActionExecutionKey: LLBBuildKey {}

extension ActionExecutionValue: LLBBuildValue {}

/// Convenience initializer.
public extension ActionExecutionKey {
    static func command(actionSpec: LLBActionSpec, inputs: [LLBActionInput], outputs: [LLBActionOutput]) -> Self {
        return ActionExecutionKey.with {
            $0.actionExecutionType = .command(CommandActionExecution.with {
                $0.actionSpec = actionSpec
                $0.inputs = inputs
                $0.outputs = outputs
            })
        }
    }

    static func mergeTrees(inputs: [LLBActionInput]) -> Self {
        return ActionExecutionKey.with {
            $0.actionExecutionType = .mergeTrees(MergeTreesActionExecution.with {
                $0.inputs = inputs
            })
        }
    }
}

/// Convenience initializer.
fileprivate extension ActionExecutionValue {
    init(outputs: [LLBDataID], stdoutID: LLBDataID?, stderrID: LLBDataID?) {
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
}

public enum ActionExecutionError: Error {
    /// Error for invalid action execution key.
    case invalid

    /// Error related to the scheduling of an action.
    case executorError(Error)

    /// Error related to an actual action (i.e. action completed but did not finish successfully).
    case actionExecutionError(LLBDataID, LLBDataID)
}

final class ActionExecutionFunction: LLBBuildFunction<ActionExecutionKey, ActionExecutionValue> {
    override func evaluate(key actionExecutionKey: ActionExecutionKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionExecutionValue> {

        switch actionExecutionKey.actionExecutionType {
        case let .command(commandKey):
            return evaluateCommand(commandKey: commandKey, fi)
        case let .mergeTrees(mergeTreesKey):
            return evaluateMergeTrees(mergeTreesKey: mergeTreesKey, fi)
        case .none:
            return engineContext.group.next().makeFailedFuture(ActionExecutionError.invalid)
        }
    }

    private func evaluateCommand(commandKey: CommandActionExecution, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionExecutionValue> {
        let actionExecutionRequest = LLBActionExecutionRequest(
            actionSpec: commandKey.actionSpec, inputs: commandKey.inputs, outputs: commandKey.outputs
        )

        return engineContext.executor.execute(request: actionExecutionRequest, engineContext: engineContext).flatMapErrorThrowing { error in
            // Action failures do not throw from the executor, so this must be an executor specific error.
            throw ActionExecutionError.executorError(error)
        }.flatMapThrowing { executionResponse in
            // If the action failed, convert it into an actual error with the dataIDs of the output logs.
            if executionResponse.exitCode != 0 {
                throw ActionExecutionError.actionExecutionError(
                    executionResponse.stdoutID,
                    executionResponse.stderrID
                )
            }

            return ActionExecutionValue(from: executionResponse)
        }
    }

    private func evaluateMergeTrees(mergeTreesKey: MergeTreesActionExecution, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionExecutionValue> {
        let inputs = mergeTreesKey.inputs
        // Skip merging if there's a single tree as input, with no path to prepend.
        if inputs.count == 1, inputs[0].type == .directory, inputs[0].path.isEmpty {
            return fi.group.next().makeSucceededFuture(ActionExecutionValue(outputs: [inputs[0].dataID], stdoutID: nil, stderrID: nil))
        }

        let client = LLBCASFSClient(engineContext.db)

        var prependedTrees = [LLBFuture<LLBCASFileTree>]()

        for input in inputs {
            prependedTrees.append(client.wrap(input.dataID, path: input.path))
        }

        // Skip merging if there is a single prepended tree.
        if prependedTrees.count == 1 {
            return prependedTrees[0].map { ActionExecutionValue(outputs: [$0.id], stdoutID: nil, stderrID: nil) }
        }

        return LLBFuture.whenAllSucceed(prependedTrees, on: fi.group.next()).flatMap { trees in
            return LLBCASFileTree.merge(trees: trees, in: self.engineContext.db)
        }.map {
            return ActionExecutionValue(outputs: [$0.id], stdoutID: nil, stderrID: nil)
        }
    }
}
