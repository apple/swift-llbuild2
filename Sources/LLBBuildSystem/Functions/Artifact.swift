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
}

/// Convenience initializer.
fileprivate extension ArtifactValue {
    init(dataID: LLBPBDataID) {
        self.dataID = dataID
    }
}

public enum ArtifactError: Error {
    case unimplemented
}

final class ArtifactFunction: LLBBuildFunction<Artifact, ArtifactValue> {
    override func evaluate(key artifact: Artifact, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ArtifactValue> {
        if case let .source(dataID) = artifact.originType {
            return fi.group.next().makeSucceededFuture(ArtifactValue(dataID: dataID))
        }

        return fi.group.next().makeFailedFuture(ArtifactError.unimplemented)
    }
}
