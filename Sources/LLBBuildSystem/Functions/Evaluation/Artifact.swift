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
    static func source(shortPath: String, root: String? = nil, dataID: LLBDataID) -> Artifact {
        return Artifact.with {
            $0.originType = .source(LLBPBDataID(dataID))
            $0.shortPath = shortPath

            if let root = root {
                $0.root = root
            }
        }
    }

    static func derivedUninitialized(shortPath: String, root: String? = nil) -> Artifact {
        return Artifact.with {
            $0.originType = nil
            $0.shortPath = shortPath

            if let root = root {
                $0.root = root
            }
        }
    }

    /// Returns the full path for the artifact, including the root.
    var path: String {
        if root.isEmpty {
            return shortPath
        } else {
            return [root, shortPath].joined(separator: "/")
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
}

public extension LLBArtifactOwner {
    init(actionID: LLBPBDataID, outputIndex: Int32) {
        self = Self.with {
            $0.actionID = actionID
            $0.outputIndex = outputIndex
        }
    }
}

/// Convenience initializer.
fileprivate extension ArtifactValue {
    init(dataID: LLBPBDataID) {
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
        default:
            break
        }

        // There are no other known originTypes, so we must be expecting a derived type.
        guard case let .derived(artifactOwner) = artifact.originType else {
            return fi.group.next().makeFailedFuture(ArtifactError.invalidOriginType)
        }

        // Request the ActionKey, then request its ActionValue and retrieve the data ID from the ActionValue to
        // associate to this artifact.
        return fi.request(ActionIDKey(dataID: artifactOwner.actionID)).flatMap { (actionKey: ActionKey) -> LLBFuture<ActionValue> in
            return fi.request(actionKey)
        }.flatMapThrowing { actionValue in
            guard actionValue.outputs.count >= artifactOwner.outputIndex + 1 else {
                throw ArtifactError.actionWithTooFewOutputs
            }
            return ArtifactValue(dataID: actionValue.outputs[Int(artifactOwner.outputIndex)])
        }
    }
}
