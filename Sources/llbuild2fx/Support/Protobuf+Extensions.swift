// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import SwiftProtobuf
import Foundation
import NIOCore

/// Convenience implementation for types that extend SwiftProtobuf.Message.
extension LLBSerializableOut where Self: SwiftProtobuf.Message {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeBytes(try self.serializedData())
    }
}

/// Convenience implementation for types that extend SwiftProtobuf.Message.
extension LLBSerializableIn where Self: SwiftProtobuf.Message {
    public init(from bytes: LLBByteBuffer) throws {
        let data = Data(bytes.readableBytesView)
        self = try Self.init(serializedData: data)
    }
}

/// Convenience implementation for types that extend SwiftProtobuf.Message
extension FXRequestKey where Self: SwiftProtobuf.Message {
    public var stableHashValue: LLBDataID {
        return LLBDataID(blake3hash: ArraySlice(try! self.serializedData()))
    }
}
