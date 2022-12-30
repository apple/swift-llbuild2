// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import NIOCore

// Mark ActionKey as an LLBBuildValue so that it can be returned by the ActionIDFunction. Since LLBBuildValue is a
// subset of LLBBuildKey, any LLBBuildKey can be made to conform to LLBBuildValue for free.
extension LLBActionKey: LLBBuildValue {}


/// An ActionID is a key used to retrieve the ActionKey referenced by its dataID. This key exists so that the retrieval
/// and deserialization of previously deserialized instances of the same action are shared. Without this, each
/// ArtifactFunction invocation would have to deserialize the ActionKey, which is potentially a problem for actions that
/// have many declared outputs.
public struct ActionIDKey: LLBBuildKey, Hashable {
    public static let identifier = "ActionIDKey"

    /// The data ID representing the serialized form of an ActionKey.
    public let dataID: LLBDataID

    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }

    public var stableHashValue: LLBDataID {
        return LLBDataID(blake3hash: ArraySlice(dataID.bytes))
    }
}

public enum ActionIDError: Error {
    case notFound
}

public final class ActionIDFunction: LLBBuildFunction<ActionIDKey, LLBActionKey> {
    public override func evaluate(key actionIDKey: ActionIDKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBActionKey> {
        return ctx.db.get(actionIDKey.dataID, ctx).flatMapThrowing { object in
            guard let object = object else {
                throw ActionIDError.notFound
            }
            return try LLBActionKey(from: object.data)
        }
    }
}
