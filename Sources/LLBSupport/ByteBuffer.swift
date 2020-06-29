// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO


public typealias LLBByteBuffer = NIO.ByteBuffer
public typealias LLBByteBufferAllocator = NIO.ByteBufferAllocator
public typealias LLBByteBufferView = NIO.ByteBufferView


public extension LLBByteBuffer {
    static func withBytes(_ data: ArraySlice<UInt8>) -> LLBByteBuffer {
        let allocator = LLBByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}

extension LLBByteBuffer {
    public mutating func reserveWriteCapacity(_ count: Int) {
        self.reserveCapacity(self.writerIndex + count)
    }

    public mutating func unsafeWrite<R>(_ writeCallback: (UnsafeMutableRawBufferPointer) -> (wrote: Int, R)) -> R {
        var returnValue: R? = nil
        self.writeWithUnsafeMutableBytes(minimumWritableBytes: 0) { ptr -> Int in
            let (wrote, ret) = writeCallback(ptr)
            returnValue = ret
            return wrote
        }
        return returnValue!
    }

}
