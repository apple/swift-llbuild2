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
    static func command(
        actionSpec: LLBActionSpec,
        inputs: [LLBArtifact],
        outputs: [LLBActionOutput],
        mnemonic: String,
        description: String,
        dynamicIdentifier: String? = nil,
        cacheableFailure: Bool = false,
        label: LLBLabel? = nil
    ) -> Self {
        return LLBActionKey.with {
            $0.actionType = .command(LLBCommandAction.with {
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

    init(actionExecutionValue: LLBActionExecutionValue) {
        self.outputs = actionExecutionValue.outputs
        if actionExecutionValue.hasStdoutID {
            self.stdoutID = actionExecutionValue.stdoutID
        }
    }
}

public enum LLBActionError: Error {
    /// Error for invalid action key.
    case invalid

    /// Error for an invalid merge tree action input.
    case invalidMergeTreeInput(String)

    /// Error in case one the inputs into the action failed to build.
    case dependencyFailure(Error)
}

extension LLBActionKey: LLBBuildEventActionDescription {
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

final class ActionFunction: LLBBuildFunction<LLBActionKey, LLBActionValue> {
    override func evaluate(
        key actionKey: LLBActionKey,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionValue> {
        switch actionKey.actionType {
        case let .command(commandKey):
            ctx.buildEventDelegate?.actionScheduled(action: actionKey)
            let resultFuture = evaluate(commandKey: commandKey, fi, ctx)
            return LLBFuture.whenAllComplete([resultFuture], on: ctx.group.next()).flatMapThrowing { results in
                switch results[0] {
                case .success(let value):
                    ctx.buildEventDelegate?.actionCompleted(
                        action: actionKey,
                        result: .success(stdoutID: value.stdoutID)
                    )
                case .failure(let error):
                    ctx.buildEventDelegate?.actionCompleted(
                        action: actionKey,
                        result: .failure(error: error)
                    )
                }
                return try results[0].get()
            }
        case let .mergeTrees(mergeTreesKey):
            return evaluate(mergeTreesKey: mergeTreesKey, fi, ctx)
        case .none:
            return ctx.group.next().makeFailedFuture(LLBActionError.invalid)
        }
    }

    private func evaluate(
        commandKey: LLBCommandAction,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionValue> {
        return fi.requestInputs(commandKey.inputs, ctx)
            .flatMap { (inputs: [(LLBArtifact, LLBArtifactValue)]) -> LLBFuture<LLBActionValue> in
                let actionExecutionKey = LLBActionExecutionKey.command(
                    actionSpec: commandKey.actionSpec,
                    inputs: inputs.map { (artifact, artifactValue) in
                        LLBActionInput(path: artifact.path, dataID: artifactValue.dataID, type: artifact.type)
                    },
                    outputs: commandKey.outputs,
                    mnemonic: commandKey.mnemonic,
                    description: commandKey.description_p,
                    // This should be empty most of the time. Only used for dynamic action registration. Need to check
                    // if the key has an empty dynamic identifier since SwiftProtobuf doesn't support optionals, but
                    // want to keep the Optional interface here.
                    dynamicIdentifier: (commandKey.dynamicIdentifier.isEmpty ? nil : commandKey.dynamicIdentifier),
                    cacheableFailure: commandKey.cacheableFailure,
                    label: (commandKey.hasLabel ? commandKey.label : nil)
                )

                return fi.request(actionExecutionKey, ctx)
                    .flatMapThrowing { (actionExecutionValue: LLBActionExecutionValue) -> LLBActionValue in
                        if actionExecutionValue.cachedFailure {
                            throw LLBActionExecutionError.actionExecutionError(actionExecutionValue.stdoutID)
                        }
                        return LLBActionValue(actionExecutionValue: actionExecutionValue)
                    }
            }
    }

    private func evaluate(
        mergeTreesKey: LLBMergeTreesAction,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionValue> {
        return fi.requestInputs(
            mergeTreesKey.inputs.map(\.artifact),
            ctx
        ).flatMap { (inputs: [(artifact: LLBArtifact, artifactValue: LLBArtifactValue)]) -> LLBFuture<LLBActionExecutionValue> in
            var actionInputs = [LLBActionInput]()
            for (index, input) in mergeTreesKey.inputs.enumerated() {
                guard inputs[index].artifact.type == .directory || !input.path.isEmpty else {
                    return ctx.group.next().makeFailedFuture(
                        LLBActionError.invalidMergeTreeInput("expected a path for the non directory artifact")
                    )
                }

                actionInputs.append(
                    LLBActionInput(
                        path: input.path,
                        dataID: inputs[index].artifactValue.dataID,
                        type: inputs[index].artifact.type
                    )
                )
            }

            let actionExecutionKey = LLBActionExecutionKey.mergeTrees(inputs: actionInputs)

            return fi.request(actionExecutionKey, ctx)
        }.map { actionExecutionValue in
            return LLBActionValue(outputs: actionExecutionValue.outputs)
        }
    }
}

extension LLBBuildFunctionInterface {
    /// Requests the values for a list of keys of the same type, returned as a tuple containing the key and the value.
    func requestInputs(_ artifacts: [LLBArtifact], _ ctx: Context) -> LLBFuture<[(LLBArtifact, LLBArtifactValue)]> {
        let requestFutures = artifacts.map { artifact in
            self.requestArtifact(artifact, ctx).map { (artifact, $0) }
        }
        return LLBFuture.whenAllComplete(requestFutures, on: ctx.group.next()).flatMapThrowing { results in
            for result in results {
                switch result {
                case .failure(let error):
                    if case LLBActionError.dependencyFailure = error {
                        throw error
                    } else {
                        throw LLBActionError.dependencyFailure(error)
                    }
                default:
                    break
                }
            }

            // Should not throw since we would have already thrown when searching for errors above.
            return try results.map { try $0.get() }
        }
    }
}
