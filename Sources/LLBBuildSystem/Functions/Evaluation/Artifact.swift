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

extension Artifact: LLBBuildKey {}
extension ArtifactValue: LLBBuildValue {}

/// Convenience initializer.
public extension Artifact {
    /// Returns a source artifact with a reference to the data ID containing artifact's contents.
    static func source(shortPath: String, roots: [String] = [], dataID: LLBDataID) -> Artifact {
        return Artifact.with {
            $0.originType = .source(dataID)
            $0.shortPath = shortPath
            $0.type = .file
            $0.roots = roots
        }
    }

    /// Returns a derived artifact that doesn't have any artifact owner information configured.
    static func derivedUninitialized(shortPath: String, roots: [String] = []) -> Artifact {
        return Artifact.with {
            $0.originType = nil
            $0.shortPath = shortPath
            $0.type = .file
            $0.roots = roots
        }
    }

    /// Returns a derived artifact that doesn't have any artifact owner information configured.
    static func derivedUninitializedDirectory(shortPath: String, roots: [String] = []) -> Artifact {
        return Artifact.with {
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

extension Artifact {
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
}

/// Convenience initializer.
fileprivate extension ArtifactValue {
    init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}

public enum ArtifactError: Error {
    case unimplemented
    case invalidOriginType
    case actionWithTooFewOutputs
}

final class ArtifactFunction: LLBBuildFunction<Artifact, ArtifactValue> {
    override func evaluate(key artifact: Artifact, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ArtifactValue> {

        // Resolve the easy states first, like no originType and source originType.
        switch artifact.originType {
        case .none:
            return fi.group.next().makeFailedFuture(ArtifactError.invalidOriginType)
        case let .source(dataID):
            return fi.group.next().makeSucceededFuture(ArtifactValue(dataID: dataID))
        case let .derivedStatic(dataID):
            return fi.group.next().makeSucceededFuture(ArtifactValue(dataID: dataID))
        default:
            break
        }

        // There are no other known originTypes, so we must be expecting a derived type.
        guard case let .derived(artifactOwner) = artifact.originType else {
            return fi.group.next().makeFailedFuture(ArtifactError.invalidOriginType)
        }

        // Request the ActionKey, then request its ActionValue and retrieve the data ID from the ActionValue to
        // associate to this artifact.
        return fi.request(RuleEvaluationKeyID(ruleEvaluationKeyID: artifactOwner.actionsOwner)).flatMap { (ruleEvaluationValue: RuleEvaluationValue) -> LLBFuture<ActionKey> in
            return fi.request(ActionIDKey(dataID: ruleEvaluationValue.actionIds[Int(artifactOwner.actionIndex)]))
        }.flatMap { (actionKey: ActionKey) -> LLBFuture<ActionValue> in
            return fi.request(actionKey)
        }.flatMapThrowing { (actionValue: ActionValue) -> ArtifactValue in
            guard actionValue.outputs.count >= artifactOwner.outputIndex + 1 else {
                throw ArtifactError.actionWithTooFewOutputs
            }
            return ArtifactValue(dataID: actionValue.outputs[Int(artifactOwner.outputIndex)])
        }
    }
}
