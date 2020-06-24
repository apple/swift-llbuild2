// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

// Mark ActionKey as an LLBBuildValue so that it can be returned by the ActionIDFunction. Since LLBBuildValue is a
// subset of LLBBuildKey, any LLBBuildKey can be made to conform to LLBBuildValue for free.
extension LLBActionKey: LLBBuildValue {}


/// An ActionID is a key used to retrieve the ActionKey referenced by its dataID. This key exists so that the retrieval
/// and deserialization of previously deserialized instances of the same action are shared. Without this, each
/// ArtifactFunction invocation would have to deserialize the ActionKey, which is potentially a problem for actions that
/// have many declared outputs.
struct ActionIDKey: LLBBuildKey {
    public static let identifier = "ActionIDKey"

    /// The data ID representing the serialized form of an ActionKey.
    let dataID: LLBDataID

    init(dataID: LLBDataID) {
        self.dataID = dataID
    }

    init(from bytes: LLBByteBuffer) throws {
        self.dataID = try LLBDataID(from: bytes)
    }

    func toBytes(into buffer: inout LLBByteBuffer) throws {
        try dataID.toBytes(into: &buffer)
    }

    public var stableHashValue: LLBDataID {
        return dataID
    }
}

enum ActionIDError: Error {
    case notFound
}

final class ActionIDFunction: LLBBuildFunction<ActionIDKey, LLBActionKey> {
    override func evaluate(key actionIDKey: ActionIDKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBActionKey> {
        return engineContext.db.get(actionIDKey.dataID).flatMapThrowing { object in
            guard let object = object else {
                throw ActionIDError.notFound
            }
            return try LLBActionKey(from: object.data)
        }
    }
}
