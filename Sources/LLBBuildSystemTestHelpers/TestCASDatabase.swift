// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import NIOCore


/// Implementation of an LLBCASDatabase to be used for tests purposes.
public class LLBTestCASDatabase: LLBCASDatabase {
    public let group: LLBFuturesDispatchGroup

    let db: LLBCASDatabase

    public init(group: LLBFuturesDispatchGroup, db: LLBCASDatabase? = nil) {
        self.group = group
        self.db = db ?? LLBInMemoryCASDatabase(group: group)
    }

    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> { self.db.supportedFeatures() }

    public func contains(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<Bool> { self.db.contains(id, ctx) }

    public func get(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<LLBCASObject?> { self.db.get(id, ctx) }

    public func identify(refs: [LLBDataID], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        self.db.identify(refs: refs, data: data, ctx)
    }

    public func put(refs: [LLBDataID], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        self.db.put(refs: refs, data: data, ctx)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        self.db.put(knownID: id, refs: refs, data: data, ctx)
    }
}
