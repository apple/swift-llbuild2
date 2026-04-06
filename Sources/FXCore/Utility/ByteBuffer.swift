// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIO
import NIOFoundationCompat

public typealias FXByteBuffer = NIO.ByteBuffer
public typealias FXByteBufferAllocator = NIO.ByteBufferAllocator
public typealias FXByteBufferView = NIO.ByteBufferView

extension FXByteBuffer {
    public static func withBytes(_ data: ArraySlice<UInt8>) -> FXByteBuffer {
        return FXByteBuffer(bytes: data)
    }

    public static func withBytes(_ data: Data) -> FXByteBuffer {
        return FXByteBuffer(data: data)
    }

    public static func withBytes(_ data: [UInt8]) -> FXByteBuffer {
        return FXByteBuffer(bytes: data)
    }
}

extension FXByteBuffer {
    public mutating func reserveWriteCapacity(_ count: Int) {
        self.reserveCapacity(self.writerIndex + count)
    }

    public mutating func unsafeWrite<R>(
        _ writeCallback: (UnsafeMutableRawBufferPointer) -> (wrote: Int, R)
    ) -> R {
        var returnValue: R? = nil
        self.writeWithUnsafeMutableBytes(minimumWritableBytes: 0) { ptr -> Int in
            let (wrote, ret) = writeCallback(ptr)
            returnValue = ret
            return wrote
        }
        return returnValue!
    }

}
