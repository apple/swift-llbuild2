// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation


/// Serializable protocol describes a structure that can be serialized
/// into a buffer of bytes, and deserialized back from the buffer of bytes.
public typealias LLBSerializable = LLBSerializableIn & LLBSerializableOut

public protocol LLBSerializableIn {
    /// Decode the given block back into a message.
    init(rawBytes: LLBByteBuffer) throws
}

public protocol LLBSerializableOut {
    /// Produce an encoded blob that fully defines the structure contents.
    func toBytes(into buffer: inout LLBByteBuffer)
}

extension LLBSerializableOut {
    public func toBytes() -> LLBByteBuffer {
        var buffer = LLBByteBufferAllocator().buffer(capacity: 0)
        toBytes(into: &buffer)
        return buffer
    }
}
