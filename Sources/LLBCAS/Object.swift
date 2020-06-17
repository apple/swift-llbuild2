// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import LLBSupport


// MARK:- CASObject Definition -

public struct LLBCASObject: Equatable {
    /// The list of references.
    public let refs: [LLBDataID]

    /// The object data.
    public let data: LLBByteBuffer

    public init(refs: [LLBDataID], data: LLBByteBuffer) {
        self.refs = refs
        self.data = data
    }
}

public extension LLBCASObject {
    init(refs: [LLBDataID], data: LLBByteBufferView) {
        self.init(refs: refs, data: LLBByteBuffer(data))
    }
}

public extension LLBCASObject {
    /// The size of the object data.
    var size: Int {
        return data.readableBytes
    }
}

// MARK:- CASObjectRepresentable -

public protocol LLBCASObjectRepresentable {
    func asCASObject() throws -> LLBCASObject
}

extension LLBCASObjectRepresentable where Self: LLBSerializableOut {
    public func asCASObject() throws -> LLBCASObject {
        return LLBCASObject(refs: [], data: try self.toBytes())
    }
}

// MARK:- CASObject Serializeable -

public extension LLBCASObject {
    init(rawBytes: Data) throws {
        let pb = try LLBPBCASObject.init(serializedData: rawBytes)
        var data = LLBByteBufferAllocator().buffer(capacity: pb.data.count)
        data.writeBytes(pb.data)
        self.init(refs: pb.refs, data: data)
    }

    func toData() throws -> Data {
        var pb = LLBPBCASObject()
        pb.refs = self.refs
        pb.data = Data(self.data.getBytes(at: 0, length: self.data.readableBytes)!)
        return try pb.serializedData()
    }
}

extension LLBCASObject: LLBSerializable {
    public init(from rawBytes: LLBByteBuffer) throws {
        let pb = try rawBytes.withUnsafeReadableBytes {
            try LLBPBCASObject.init(serializedData: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!), count: $0.count, deallocator: .none))
        }
        let refs = pb.refs
        var data = LLBByteBufferAllocator().buffer(capacity: pb.data.count)
        data.writeBytes(pb.data)
        self.init(refs: refs, data: data)
    }

    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeBytes(try self.toData())
    }

}

