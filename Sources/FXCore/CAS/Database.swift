// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSCUtility

/// Error wrappers that implementations may use to communicate desired higher
/// level responses.
public enum FXCASDatabaseError: Error {
    /// The database encountered a network related error that may resolve if the
    /// operation is tried again (with some delay).
    case retryableNetworkError(Error)

    /// The database encountered a network related error that is not recoverable.
    case terminalNetworkError(Error)
}

/// Features supported by a CAS Database
public struct FXCASFeatures: Codable {

    /// Whether a database is "ID preserving"
    ///
    /// An ID preserving database will *always* honor the id passed to a
    /// `put(knownID: ...)` request. i.e. on success the returned
    /// DataID will match.
    public let preservesIDs: Bool

    public init(preservesIDs: Bool = true) {
        self.preservesIDs = preservesIDs
    }
}

/// A content-addressable database protocol
///
/// THREAD-SAFETY: The database is expected to be thread-safe.
public protocol FXCASDatabase: AnyObject & Sendable {
    var group: FXFuturesDispatchGroup { get }

    /// Get the supported features of this database implementation
    func supportedFeatures() -> FXFuture<FXCASFeatures>

    /// Check if the database contains the given `id`.
    func contains(_ id: FXDataID, _ ctx: Context) -> FXFuture<Bool>

    /// Get the object corresponding to the given `id`.
    ///
    /// - Parameters:
    ///   - id: The id of the object to look up
    /// - Returns: The object, or nil if not present in the database.
    func get(_ id: FXDataID, _ ctx: Context) -> FXFuture<FXCASObject?>

    /// Calculate the DataID for the given CAS object.
    ///
    /// The implementation *MUST* return a valid content-address, such
    /// that a subsequent call to `put(knownID:...` will return an identical
    /// `id`. This method should be implemented as efficiently as possible,
    /// ideally locally.
    ///
    /// NOTE: The implementations *MAY* store the content, as if it were `put`.
    /// Clients *MAY NOT* assume the data has been written.
    ///
    ///
    /// - Parameters:
    ///    - refs: The list of objects references.
    ///    - data: The object contents.
    /// - Returns: The id representing the combination of contents and refs.
    func identify(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID>

    /// Store an object.
    ///
    /// - Parameters:
    ///    - refs: The list of objects references.
    ///    - data: The object contents.
    /// - Returns: The id representing the combination of contents and refs.
    func put(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID>

    /// Store an object with a known id.
    ///
    /// In such situations, the `id` *MUST* be a valid content-address for the
    /// object, such that there *MUST NOT* be any other combination of refs
    /// and data which could yield the same `id`.  The `id`, however, *MAY*
    /// be different from the id the database would otherwise have assigned given
    /// the content without a known ID.
    ///
    /// NOTE: The implementation *MAY* choose to reject the known ID, and store
    /// the data under its own.  The client *MUST* respect the provided result ID,
    /// and *MAY NOT* assume that a successful write allows access under the
    /// provided `id`.
    ///
    /// - Parameters:
    ///    - id: The id of the object, if known.
    ///    - refs: The list of object references.
    ///    - data: The object contents.
    func put(knownID id: FXDataID, refs: [FXDataID], data: FXByteBuffer, _ ctx: Context)
        -> FXFuture<FXDataID>
}

extension FXCASDatabase {
    @inlinable
    public func identify(_ object: FXCASObject, _ ctx: Context) -> FXFuture<FXDataID> {
        return identify(refs: object.refs, data: object.data, ctx)
    }

    @inlinable
    public func put(_ object: FXCASObject, _ ctx: Context) -> FXFuture<FXDataID> {
        return put(refs: object.refs, data: object.data, ctx)
    }

    @inlinable
    public func put(knownID id: FXDataID, object: FXCASObject, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        return put(knownID: id, refs: object.refs, data: object.data, ctx)
    }
}

extension FXCASDatabase {
    @inlinable
    public func identify(refs: [FXDataID], data: FXByteBufferView, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        return identify(refs: refs, data: FXByteBuffer(data), ctx)
    }

    @inlinable
    public func put(refs: [FXDataID], data: FXByteBufferView, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        return put(refs: refs, data: FXByteBuffer(data), ctx)
    }

    @inlinable
    public func put(data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        return self.put(refs: [], data: data, ctx)
    }

    @inlinable
    public func put(
        knownID id: FXDataID, refs: [FXDataID], data: FXByteBufferView, _ ctx: Context
    ) -> FXFuture<FXDataID> {
        return put(knownID: id, refs: refs, data: FXByteBuffer(data), ctx)
    }
}

/// Support storing and retrieving a CAS database from a context
extension Context {
    public static func with(_ db: FXCASDatabase) -> Context {
        return Context(dictionaryLiteral: (ObjectIdentifier(FXCASDatabase.self), db as Any))
    }

    public var db: FXCASDatabase {
        get {
            guard let db = self[ObjectIdentifier(FXCASDatabase.self), as: FXCASDatabase.self]
            else {
                fatalError("no CAS database")
            }
            return db
        }
        set {
            self[ObjectIdentifier(FXCASDatabase.self)] = newValue
        }
    }
}
