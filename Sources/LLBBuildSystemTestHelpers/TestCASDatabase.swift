// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBUtil

/// Implementation of an LLBCASDatabase to be used for tests purposes.
public class LLBTestCASDatabase: LLBCASDatabase {
    public let group: LLBFuturesDispatchGroup

    let db: LLBCASDatabase

    public init(group: LLBFuturesDispatchGroup, db: LLBCASDatabase? = nil) {
        self.group = group
        self.db = db ?? LLBInMemoryCASDatabase(group: group)
    }

    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> { self.db.supportedFeatures() }

    public func contains(_ id: LLBDataID) -> LLBFuture<Bool> { self.db.contains(id) }

    public func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?> { self.db.get(id) }

    public func identify(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        self.db.identify(refs: refs, data: data)
    }

    public func put(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        self.db.put(refs: refs, data: data)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        self.db.put(knownID: id, refs: refs, data: data)
    }
}
