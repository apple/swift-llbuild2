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
}

/// Convenience initializer.
fileprivate extension ActionExecutionValue {
    init(from executionResponse: LLBActionExecutionResponse) {
        self.outputs = executionResponse.outputs
        self.stdoutID = executionResponse.stdoutID
        self.stderrID = executionResponse.stderrID
    }
}

public enum ActionExecutionError: Error {
    /// Error for unimplemented functionality.
    case unimplemented

    /// Error related to the scheduling of an action.
    case schedulingError(Error)

    /// Error related to an actual action (i.e. action completed but did not finish successfully).
    case actionExecutionError(LLBDataID, LLBDataID)
}

final class ActionExecutionFunction: LLBBuildFunction<ActionExecutionKey, ActionExecutionValue> {
    override func evaluate(key actionExecutionKey: ActionExecutionKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionExecutionValue> {

        switch actionExecutionKey.actionExecutionType {
        case let .command(commandKey):
            return evaluateCommand(commandKey: commandKey, fi)
        default:
            return engineContext.group.next().makeFailedFuture(ActionExecutionError.unimplemented)
        }
    }

    private func evaluateCommand(commandKey: CommandActionExecution, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionExecutionValue> {
        let actionExecutionRequest = LLBActionExecutionRequest(
            actionSpec: commandKey.actionSpec, inputs: commandKey.inputs, outputs: commandKey.outputs
        )

        return engineContext.executor.execute(request: actionExecutionRequest, engineContext: engineContext).flatMapErrorThrowing { error in
            // Action failures do not throw from the executor, so any errors at this stage must be scheduling errors
            // from the executor.
            throw ActionExecutionError.schedulingError(error)
        }.flatMapThrowing { executionResponse in
            // If the action failed, convert it into an actual error with the dataIDs of the output logs.
            if executionResponse.exitCode != 0 {
                throw ActionExecutionError.actionExecutionError(
                    LLBDataID(executionResponse.stdoutID),
                    LLBDataID(executionResponse.stderrID)
                )
            }

            return ActionExecutionValue(from: executionResponse)
        }
    }
}
