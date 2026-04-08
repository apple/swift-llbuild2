// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCUtility

/// Wraps any ``FXTypedCASDatabase`` to present it as an ``FXCASDatabase``.
///
/// When `DB` is already an ``FXCASDatabase`` (i.e. `DB.DataID == FXDataID`
/// and `DB.CASObject == FXCASObject`), the adapter is a trivial passthrough.
/// Otherwise it converts between the custom types and the concrete types via
/// their bytes representations.
public final class FXCASDatabaseAdapter<DB: FXTypedCASDatabase>: @unchecked Sendable {
    public let underlying: DB

    public init(_ db: DB) {
        self.underlying = db
    }
}

// MARK: - Passthrough conformance when DB is already FXCASDatabase

extension FXCASDatabaseAdapter: FXTypedCASDatabase where DB.DataID == FXDataID, DB.CASObject == FXCASObject {
    public typealias DataID = FXDataID
    public typealias CASObject = FXCASObject

    public var group: FXFuturesDispatchGroup { underlying.group }

    public func supportedFeatures() -> FXFuture<FXCASFeatures> {
        underlying.supportedFeatures()
    }

    public func contains(_ id: FXDataID, _ ctx: Context) -> FXFuture<Bool> {
        underlying.contains(id, ctx)
    }

    public func get(_ id: FXDataID, _ ctx: Context) -> FXFuture<FXCASObject?> {
        underlying.get(id, ctx)
    }

    public func identify(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        underlying.identify(refs: refs, data: data, ctx)
    }

    public func put(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        underlying.put(refs: refs, data: data, ctx)
    }

    public func put(knownID id: FXDataID, refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        underlying.put(knownID: id, refs: refs, data: data, ctx)
    }
}

extension FXCASDatabaseAdapter: FXCASDatabase where DB.DataID == FXDataID, DB.CASObject == FXCASObject {}
