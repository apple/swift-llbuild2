// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2


extension LLBArtifact: LLBBuildKey {}
extension LLBArtifactValue: LLBBuildValue {}

/// Convenience initializer.
public extension LLBArtifact {
    /// Returns a source artifact with a reference to the data ID containing artifact's contents.
    static func source(shortPath: String, roots: [String] = [], dataID: LLBDataID) -> LLBArtifact {
        return LLBArtifact.with {
            $0.originType = .source(dataID)
            $0.shortPath = shortPath
            $0.type = .file
            $0.roots = roots
        }
    }

    /// Returns a source artifact with a reference to the data ID containing artifact's contents.
    static func sourceDirectory(shortPath: String, roots: [String] = [], dataID: LLBDataID) -> LLBArtifact {
        return LLBArtifact.with {
            $0.originType = .source(dataID)
            $0.shortPath = shortPath
            $0.type = .directory
            $0.roots = roots
        }
    }

    /// Returns a derived artifact that doesn't have any artifact owner information configured.
    static func derivedUninitialized(shortPath: String, roots: [String] = []) -> LLBArtifact {
        return LLBArtifact.with {
            $0.originType = nil
            $0.shortPath = shortPath
            $0.type = .file
            $0.roots = roots
        }
    }

    /// Returns a derived artifact that doesn't have any artifact owner information configured.
    static func derivedUninitializedDirectory(shortPath: String, roots: [String] = []) -> LLBArtifact {
        return LLBArtifact.with {
            $0.originType = nil
            $0.shortPath = shortPath
            $0.type = .directory
            $0.roots = roots
        }
    }

    /// Returns the full path for the artifact, including the root.
    var path: String {
        if roots.isEmpty {
            return shortPath
        } else {
            return (roots + [shortPath]).joined(separator: "/")
        }
    }

    func asActionOutput() -> LLBActionOutput {
        return LLBActionOutput(path: path, type: type)
    }
}

extension LLBArtifact {
    func updateOwner(owner: LLBArtifactOwner) {
        precondition(originType == nil, "Artifact was already associated to an action")
        self.originType = .derived(owner)
    }

    func updateID(dataID: LLBDataID) {
        precondition(originType == nil, "Artifact was already associated to an action")
        self.originType = .derivedStatic(dataID)
    }
}

/// Convenience initializer.
public extension LLBArtifactOwner {
    init(actionsOwner: LLBDataID, actionIndex: Int32, outputIndex: Int32) {
        self = Self.with {
            $0.actionsOwner = actionsOwner
            $0.actionIndex = actionIndex
            $0.outputIndex = outputIndex
        }
    }

    init(actionsOwner: LLBDataID, actionIndex: Int32, unconditionalOutputIndex: Int32) {
        self = Self.with {
            $0.actionsOwner = actionsOwner
            $0.actionIndex = actionIndex
            $0.unconditionalOutputIndex = unconditionalOutputIndex
        }
    }
}

/// Convenience initializer.
fileprivate extension LLBArtifactValue {
    init(dataID: LLBDataID, logsID: LLBDataID? = nil) {
        self = Self.with {
            $0.dataID = dataID
            if let logsID = logsID {
                $0.logsID = logsID
            }
        }
    }
}

public enum LLBArtifactError: Error {
    case unimplemented
    case invalidOriginType
    case invalidOutputType
    case actionWithTooFewOutputs
    case unconditionalOutput(LLBDataID)
}

final class ArtifactFunction: LLBBuildFunction<LLBArtifact, LLBArtifactValue> {
    override func evaluate(key artifact: LLBArtifact, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBArtifactValue> {

        // Resolve the easy states first, like no originType and source originType.
        switch artifact.originType {
        case .none:
            return ctx.group.next().makeFailedFuture(LLBArtifactError.invalidOriginType)
        case let .source(dataID):
            return ctx.group.next().makeSucceededFuture(LLBArtifactValue(dataID: dataID))
        case let .derivedStatic(dataID):
            return ctx.group.next().makeSucceededFuture(LLBArtifactValue(dataID: dataID))
        default:
            break
        }

        // There are no other known originTypes, so we must be expecting a derived type.
        guard case let .derived(artifactOwner) = artifact.originType else {
            return ctx.group.next().makeFailedFuture(LLBArtifactError.invalidOriginType)
        }

        // Request the ActionKey, then request its ActionValue and retrieve the data ID from the ActionValue to
        // associate to this artifact.
        return fi.request(LLBRuleEvaluationKeyID(ruleEvaluationKeyID: artifactOwner.actionsOwner), ctx).flatMap { (ruleEvaluationValue: LLBRuleEvaluationValue) -> LLBFuture<LLBActionKey> in
            return fi.request(ActionIDKey(dataID: ruleEvaluationValue.actionIds[Int(artifactOwner.actionIndex)]), ctx)
        }.flatMap { (actionKey: LLBActionKey) -> LLBFuture<LLBActionValue> in
            return fi.request(actionKey, ctx)
        }.flatMapThrowing { (actionValue: LLBActionValue) -> LLBArtifactValue in
            let outputList: [LLBDataID]
            let artifactIndex: Int32
            switch artifactOwner.outputType {
            case .outputIndex(let index):
                outputList = actionValue.outputs
                artifactIndex = index
            case .unconditionalOutputIndex(let index):
                outputList = actionValue.unconditionalOutputs
                artifactIndex = index
            default:
                throw LLBArtifactError.invalidOutputType
            }

            guard outputList.count >= artifactIndex + 1 else {
                throw LLBArtifactError.actionWithTooFewOutputs
            }
            return LLBArtifactValue(
                dataID: outputList[Int(artifactIndex)],
                logsID: actionValue.hasStdoutID ? actionValue.stdoutID : nil
            )
        }.flatMapErrorThrowing { error in
            if
                case let .actionExecutionError(_, unconditionalOutputs) = error as? LLBActionExecutionError,
                case let .unconditionalOutputIndex(index) = artifactOwner.outputType,
                unconditionalOutputs.count >= index + 1
            {
                // We throw here instead of returning a valid ArtifactValue to avoid any kind of caching mechanism
                // the build system might be configured with.
                throw LLBArtifactError.unconditionalOutput(unconditionalOutputs[Int(index)])
            }
            throw error
        }
    }
}
