// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

// LLBCodable support for common types used in llbuild2. Should be expanded as more types are needed. This is not
// meant ot be a full featured serialization library support, so there's no need to be eager and add support for most of
// the POD types in Swift, just the ones that we are interested in in the short term, or that clients of llbuild2
// request support of.

extension String: LLBCodable {
    public func encode() throws -> LLBByteBuffer {
        var bytes = LLBByteBufferAllocator().buffer(capacity: self.count)
        bytes.writeString(self)
        return bytes
    }

    public init(from bytes: LLBByteBuffer) throws {
        var mutableBytes = bytes
        guard let decoded = mutableBytes.readString(length: bytes.readableBytes) else {
            throw LLBCodableError.unknownError("could not decode String bytes")
        }
        self = decoded

    }
}

// Int currently support doesn't handle endian-ness. These are mostly used as basic data types for testing on local
// systems. For more complex data types that use Ints, each type should account for the serialization mechanism.
extension Int: LLBCodable {
    public func encode() throws -> LLBByteBuffer {
        let size = MemoryLayout<Int>.size
        var bytes = LLBByteBufferAllocator().buffer(capacity: size)
        bytes.writeInteger(self)
        return bytes
    }

    public init(from bytes: LLBByteBuffer) throws {
        var mutableBytes = bytes
        guard let decoded: Int = mutableBytes.readInteger() else {
            throw LLBCodableError.unknownError("could not decode Int bytes")
        }
        self = decoded
    }
}
