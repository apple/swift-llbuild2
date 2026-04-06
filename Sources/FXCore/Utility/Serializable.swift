// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore

/// Serializable protocol describes a structure that can be serialized
/// into a buffer of bytes, and deserialized back from the buffer of bytes.
public typealias FXSerializable = FXSerializableIn & FXSerializableOut

public enum FXSerializableError: Error {
    case unknownError(String)
}

public protocol FXSerializableIn {
    /// Decode the given block back into a message.
    init(from rawBytes: FXByteBuffer) throws
}

public protocol FXSerializableOut {
    /// Produce an encoded blob that fully defines the structure contents.
    func toBytes(into buffer: inout FXByteBuffer) throws
}

extension FXSerializableOut {
    public func toBytes() throws -> FXByteBuffer {
        var buffer = FXByteBufferAllocator().buffer(capacity: 0)
        try toBytes(into: &buffer)
        return buffer
    }
}
