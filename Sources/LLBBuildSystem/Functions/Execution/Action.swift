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

extension ActionKey: LLBBuildKey {}
extension ActionValue: LLBBuildValue {}

/// Convenience initializer.
public extension ActionKey {
    static func command(actionSpec: LLBActionSpec, inputs: [Artifact], outputs: [LLBActionOutput]) -> Self {
        return ActionKey.with {
            $0.actionType = .command(CommandAction.with {
                $0.actionSpec = actionSpec
                $0.inputs = inputs
                $0.outputs = outputs
            })
        }
    }

    static func mergeTrees(inputs: [(artifact: Artifact, path: String?)]) -> Self {
        return ActionKey.with {
            $0.actionType = .mergeTrees(MergeTreesAction.with {
                $0.inputs = inputs.map { MergeTreesActionInput(artifact: $0.artifact, path: $0.path) }
            })
        }
    }
}

fileprivate extension MergeTreesActionInput {
    init(artifact: Artifact, path: String?) {
        self.artifact = artifact
        if let path = path {
            self.path = path
        }
    }
}

/// Convenience initializer.
fileprivate extension ActionValue {
    init(outputs: [LLBDataID]) {
        self.outputs = outputs
    }
}

public enum ActionError: Error {
    /// Error for invalid action key.
    case invalid

    /// Error for an invalid merge tree action input.
    case invalidMergeTreeInput(String)
}

final class ActionFunction: LLBBuildFunction<ActionKey, ActionValue> {
    override func evaluate(key actionKey: ActionKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionValue> {
        switch actionKey.actionType {
        case let .command(commandKey):
            return evaluate(commandKey: commandKey, fi)
        case let .mergeTrees(mergeTreesKey):
            return evaluate(mergeTreesKey: mergeTreesKey, fi)
        case .none:
            return engineContext.group.next().makeFailedFuture(ActionError.invalid)
        }
    }

    private func evaluate(commandKey: CommandAction, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionValue> {
        return fi.requestKeyed(commandKey.inputs).flatMap { (inputs: [(Artifact, ArtifactValue)]) -> LLBFuture<ActionExecutionValue> in
            let actionExecutionKey = ActionExecutionKey.command(
                actionSpec: commandKey.actionSpec,
                inputs: inputs.map { (artifact, artifactValue) in
                    LLBActionInput(path: artifact.path, dataID: artifactValue.dataID, type: artifact.type)
                },
                outputs: commandKey.outputs
            )

            return fi.request(actionExecutionKey)
        }.map { actionExecutionValue in
            return ActionValue(outputs: actionExecutionValue.outputs)
        }
    }

    private func evaluate(mergeTreesKey: MergeTreesAction, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ActionValue> {
        return fi.requestKeyed(mergeTreesKey.inputs.map(\.artifact)).flatMap { (inputs: [(artifact: Artifact, artifactValue: ArtifactValue)]) -> LLBFuture<ActionExecutionValue> in
            var actionInputs = [LLBActionInput]()
            for (index, input) in mergeTreesKey.inputs.enumerated() {
                guard inputs[index].artifact.type == .directory || !input.path.isEmpty else {
                    return fi.group.next().makeFailedFuture(ActionError.invalidMergeTreeInput("expected a path for the non directory artifact"))
                }

                actionInputs.append(
                    LLBActionInput(path: input.path, dataID: inputs[index].artifactValue.dataID, type: inputs[index].artifact.type)
                )
            }

            let actionExecutionKey = ActionExecutionKey.mergeTrees(inputs: actionInputs)
            return fi.request(actionExecutionKey)
        }.map { actionExecutionValue in
            return ActionValue(outputs: actionExecutionValue.outputs)
        }
    }
}
