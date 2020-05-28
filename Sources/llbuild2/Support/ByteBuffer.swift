// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO

public typealias ByteBuffer = NIO.ByteBuffer
public typealias ByteBufferAllocator = NIO.ByteBufferAllocator

public extension ByteBuffer {
    static func withBytes(_ data: ArraySlice<UInt8>) -> ByteBuffer {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}
