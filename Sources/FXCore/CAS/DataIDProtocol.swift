// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

/// Protocol abstracting the identity type used by a CAS database.
///
/// Conforming types represent content-addressed digests. The concrete
/// ``FXDataID`` type conforms to this protocol.
public protocol FXDataIDProtocol: Codable, Comparable, Hashable, Sendable {
    /// The raw bytes of the digest.
    var bytes: Data { get }

    /// Create from raw bytes, returning nil if the bytes are invalid.
    init?(bytes: [UInt8])

    /// Create a direct-hash id from the given bytes.
    init(directHash bytes: [UInt8])
}
