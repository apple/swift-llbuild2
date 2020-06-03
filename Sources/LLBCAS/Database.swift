// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import LLBSupport


/// Features supported by a CAS Database
public struct LLBCASFeatures: Codable {
    
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
public protocol LLBCASDatabase: class {
    var group: LLBFuturesDispatchGroup { get }

    /// Get the supported features of this database implementation
    func supportedFeatures() -> LLBFuture<LLBCASFeatures>

    /// Check if the database contains the given `id`.
    func contains(_ id: LLBDataID) -> LLBFuture<Bool>
    
    /// Get the object corresponding to the given `id`.
    ///
    /// - Parameters:
    ///   - id: The id of the object to look up
    /// - Returns: The object, or nil if not present in the database.
    func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?>
    
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
    func identify(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID>

    /// Store an object.
    ///
    /// - Parameters:
    ///    - refs: The list of objects references.
    ///    - data: The object contents.
    /// - Returns: The id representing the combination of contents and refs.
    func put(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID>
    
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
    func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID>
}

public extension LLBCASDatabase {
    func identify(refs: [LLBDataID], data: LLBByteBufferView) -> LLBFuture<LLBDataID> {

        return identify(refs: refs, data: LLBByteBuffer(data))
    }

    func put(refs: [LLBDataID], data: LLBByteBufferView) -> LLBFuture<LLBDataID> {

        return put(refs: refs, data: LLBByteBuffer(data))
    }

    func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBufferView) -> LLBFuture<LLBDataID> {
        return put(knownID: id, refs: refs, data: LLBByteBuffer(data))
    }
}
