// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

/// Protocol abstracting a CAS object with typed references.
///
/// Conforming types hold a list of references (``DataID``) and a data
/// payload. The concrete ``FXCASObject`` type conforms to this protocol.
public protocol FXCASObjectProtocol<DataID>: Equatable, Sendable {
    associatedtype DataID: FXDataIDProtocol

    /// The list of references.
    var refs: [DataID] { get }

    /// The object data.
    var data: FXByteBuffer { get }

    /// The size of the object data in bytes.
    var size: Int { get }

    /// Create a CAS object from refs and data.
    init(refs: [DataID], data: FXByteBuffer)
}
