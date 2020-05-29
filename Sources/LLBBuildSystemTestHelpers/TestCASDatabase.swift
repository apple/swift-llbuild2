// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

public enum LLBTestCASDatabaseError: Error {
    case unimplemented
}

/// Implementation of an LLBCASDatabase to be used for tests purposes.
public class LLBTestCASDatabase: LLBCASDatabase {
    let group: LLBFuturesDispatchGroup

    init(group: LLBFuturesDispatchGroup) {
        self.group = group
    }

    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        return group.next().makeFailedFuture(LLBTestCASDatabaseError.unimplemented)
    }

    public func contains(_ id: LLBDataID) -> LLBFuture<Bool> {
        return group.next().makeFailedFuture(LLBTestCASDatabaseError.unimplemented)
    }

    public func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?> {
        return group.next().makeFailedFuture(LLBTestCASDatabaseError.unimplemented)
    }

    public func put(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        return group.next().makeFailedFuture(LLBTestCASDatabaseError.unimplemented)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        return group.next().makeFailedFuture(LLBTestCASDatabaseError.unimplemented)
    }
}
