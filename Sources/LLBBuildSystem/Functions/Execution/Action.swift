// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

extension LLBActionKey: LLBBuildKey {}
extension LLBActionValue: LLBBuildValue {}

/// Convenience initializer.
public extension LLBActionKey {
    static func command(actionSpec: LLBActionSpec, inputs: [LLBArtifact], outputs: [LLBActionOutput]) -> Self {
        return LLBActionKey.with {
            $0.actionType = .command(LLBCommandAction.with {
                $0.actionSpec = actionSpec
                $0.inputs = inputs
                $0.outputs = outputs
            })
        }
    }

    static func mergeTrees(inputs: [(artifact: LLBArtifact, path: String?)]) -> Self {
        return LLBActionKey.with {
            $0.actionType = .mergeTrees(LLBMergeTreesAction.with {
                $0.inputs = inputs.map { LLBMergeTreesActionInput(artifact: $0.artifact, path: $0.path) }
            })
        }
    }
}

fileprivate extension LLBMergeTreesActionInput {
    init(artifact: LLBArtifact, path: String?) {
        self.artifact = artifact
        if let path = path {
            self.path = path
        }
    }
}

/// Convenience initializer.
fileprivate extension LLBActionValue {
    init(outputs: [LLBDataID]) {
        self.outputs = outputs
    }
}

public enum LLBActionError: Error {
    /// Error for invalid action key.
    case invalid

    /// Error for an invalid merge tree action input.
    case invalidMergeTreeInput(String)
}

final class ActionFunction: LLBBuildFunction<LLBActionKey, LLBActionValue> {
    override func evaluate(key actionKey: LLBActionKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBActionValue> {
        switch actionKey.actionType {
        case let .command(commandKey):
            return evaluate(commandKey: commandKey, fi)
        case let .mergeTrees(mergeTreesKey):
            return evaluate(mergeTreesKey: mergeTreesKey, fi)
        case .none:
            return engineContext.group.next().makeFailedFuture(LLBActionError.invalid)
        }
    }

    private func evaluate(commandKey: LLBCommandAction, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBActionValue> {
        return fi.requestKeyed(commandKey.inputs).flatMap { (inputs: [(LLBArtifact, LLBArtifactValue)]) -> LLBFuture<LLBActionExecutionValue> in
            let actionExecutionKey = LLBActionExecutionKey.command(
                actionSpec: commandKey.actionSpec,
                inputs: inputs.map { (artifact, artifactValue) in
                    LLBActionInput(path: artifact.path, dataID: artifactValue.dataID, type: artifact.type)
                },
                outputs: commandKey.outputs
            )

            return fi.request(actionExecutionKey)
        }.map { actionExecutionValue in
            return LLBActionValue(outputs: actionExecutionValue.outputs)
        }
    }

    private func evaluate(mergeTreesKey: LLBMergeTreesAction, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBActionValue> {
        return fi.requestKeyed(mergeTreesKey.inputs.map(\.artifact)).flatMap { (inputs: [(artifact: LLBArtifact, artifactValue: LLBArtifactValue)]) -> LLBFuture<LLBActionExecutionValue> in
            var actionInputs = [LLBActionInput]()
            for (index, input) in mergeTreesKey.inputs.enumerated() {
                guard inputs[index].artifact.type == .directory || !input.path.isEmpty else {
                    return fi.group.next().makeFailedFuture(LLBActionError.invalidMergeTreeInput("expected a path for the non directory artifact"))
                }

                actionInputs.append(
                    LLBActionInput(path: input.path, dataID: inputs[index].artifactValue.dataID, type: inputs[index].artifact.type)
                )
            }

            let actionExecutionKey = LLBActionExecutionKey.mergeTrees(inputs: actionInputs)
            return fi.request(actionExecutionKey)
        }.map { actionExecutionValue in
            return LLBActionValue(outputs: actionExecutionValue.outputs)
        }
    }
}
