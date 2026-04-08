// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
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

/// A content-addressable database protocol using the concrete ``FXDataID``
/// and ``FXCASObject`` types.
///
/// This refines ``FXTypedCASDatabase`` with fixed associated types. Existing
/// conformers (e.g. ``FXInMemoryCASDatabase``) continue to work unchanged.
///
/// THREAD-SAFETY: The database is expected to be thread-safe.
public protocol FXCASDatabase: FXTypedCASDatabase
    where DataID == FXDataID, CASObject == FXCASObject {}

