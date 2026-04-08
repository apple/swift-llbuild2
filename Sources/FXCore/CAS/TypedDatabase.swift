// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCUtility

/// A content-addressable database protocol parameterized over its identity
/// and object types.
///
/// This is the generalized form of ``FXCASDatabase``. Clients that wish to
/// supply their own CAS types conform to this protocol directly, while the
/// existing ``FXCASDatabase`` refines it with concrete ``FXDataID`` /
/// ``FXCASObject`` associated types.
///
/// THREAD-SAFETY: The database is expected to be thread-safe.
public protocol FXTypedCASDatabase<DataID, CASObject>: AnyObject & Sendable {
    associatedtype DataID: FXDataIDProtocol
    associatedtype CASObject: FXCASObjectProtocol where CASObject.DataID == DataID

    var group: FXFuturesDispatchGroup { get }

    /// Get the supported features of this database implementation.
    func supportedFeatures() -> FXFuture<FXCASFeatures>

    /// Check if the database contains the given `id`.
    func contains(_ id: DataID, _ ctx: Context) -> FXFuture<Bool>

    /// Get the object corresponding to the given `id`.
    func get(_ id: DataID, _ ctx: Context) -> FXFuture<CASObject?>

    /// Calculate the DataID for the given CAS object.
    func identify(refs: [DataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<DataID>

    /// Store an object.
    func put(refs: [DataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<DataID>

    /// Store an object with a known id.
    func put(knownID id: DataID, refs: [DataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<DataID>
}

// MARK: - Convenience extensions on FXTypedCASDatabase

extension FXTypedCASDatabase {
    @inlinable
    public func identify(_ object: CASObject, _ ctx: Context) -> FXFuture<DataID> {
        return identify(refs: object.refs, data: object.data, ctx)
    }

    @inlinable
    public func put(_ object: CASObject, _ ctx: Context) -> FXFuture<DataID> {
        return put(refs: object.refs, data: object.data, ctx)
    }

    @inlinable
    public func put(knownID id: DataID, object: CASObject, _ ctx: Context) -> FXFuture<DataID> {
        return put(knownID: id, refs: object.refs, data: object.data, ctx)
    }

    @inlinable
    public func put(data: FXByteBuffer, _ ctx: Context) -> FXFuture<DataID> {
        return self.put(refs: [], data: data, ctx)
    }

    @inlinable
    public func identify(refs: [DataID], data: FXByteBufferView, _ ctx: Context) -> FXFuture<DataID> {
        return identify(refs: refs, data: FXByteBuffer(data), ctx)
    }

    @inlinable
    public func put(refs: [DataID], data: FXByteBufferView, _ ctx: Context) -> FXFuture<DataID> {
        return put(refs: refs, data: FXByteBuffer(data), ctx)
    }

    @inlinable
    public func put(knownID id: DataID, refs: [DataID], data: FXByteBufferView, _ ctx: Context) -> FXFuture<DataID> {
        return put(knownID: id, refs: refs, data: FXByteBuffer(data), ctx)
    }
}
