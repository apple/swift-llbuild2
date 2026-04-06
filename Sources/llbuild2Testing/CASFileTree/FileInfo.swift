// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import Foundation
import NIOCore
import SwiftProtobuf

extension LLBFileInfo: FXSerializable {
    /// Decode the given block back into a message.
    @inlinable
    package init(from rawBytes: FXByteBuffer) throws {
        self = try Self.deserialize(from: rawBytes)
    }

    /// Produce an encoded blob that fully defines the structure contents.
    @inlinable
    package func toBytes(into buffer: inout FXByteBuffer) throws {
        buffer.writeBytes(try serializedData())
    }
}

extension LLBFileInfo {
    @inlinable
    package static func deserialize(from array: [UInt8]) throws -> Self {
        return try array.withUnsafeBufferPointer { try deserialize(from: $0) }
    }

    @inlinable
    package static func deserialize(from bytes: ArraySlice<UInt8>) throws -> Self {
        return try bytes.withUnsafeBufferPointer { try deserialize(from: $0) }
    }

    @inlinable
    package static func deserialize(from buffer: FXByteBuffer) throws -> Self {
        return try buffer.withUnsafeReadableBytesWithStorageManagement { (buffer, mgr) in
            _ = mgr.retain()
            return try Self.init(
                serializedBytes: Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                    count: buffer.count,
                    deallocator: .custom({ _, _ in mgr.release() }
                    )))
        }
    }

    @inlinable
    package static func deserialize(from buffer: UnsafeBufferPointer<UInt8>) throws -> Self {
        return try Self.init(
            serializedBytes: Data(
                // NOTE: This doesn't actually mutate, which is why this is safe.
                bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                count: buffer.count, deallocator: .none))
    }
}
