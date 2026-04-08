// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import NIOFoundationCompat

// MARK:- CASObject Definition -

public struct FXCASObject: Equatable, Sendable {
    /// The list of references.
    public let refs: [FXDataID]

    /// The object data.
    public let data: FXByteBuffer

    public init(refs: [FXDataID], data: FXByteBuffer) {
        self.refs = refs
        self.data = data
    }
}

extension FXCASObject {
    public init(refs: [FXDataID], data: FXByteBufferView) {
        self.init(refs: refs, data: FXByteBuffer(data))
    }
}

extension FXCASObject {
    /// The size of the object data.
    public var size: Int {
        return data.readableBytes
    }
}

// MARK:- FXCASObjectProtocol conformance -

extension FXCASObject: FXCASObjectProtocol {
    public typealias DataID = FXDataID
}

// MARK:- CASObjectRepresentable -

public protocol FXCASObjectRepresentable {
    func asCASObject() throws -> FXCASObject
}
public protocol FXCASObjectConstructable {
    init(from casObject: FXCASObject) throws
}

// MARK:- CASObject Serializeable -

extension FXCASObject {
    public init(rawBytes: Data) throws {
        let pb = try FXPBCASObject(serializedBytes: rawBytes)
        var data = FXByteBufferAllocator().buffer(capacity: pb.data.count)
        data.writeBytes(pb.data)
        self.init(refs: pb.refs, data: data)
    }

    public func toData() throws -> Data {
        var pb = FXPBCASObject()
        pb.refs = self.refs
        pb.data = Data(buffer: self.data)
        return try pb.serializedData()
    }
}

extension FXCASObject: FXSerializable {
    public init(from rawBytes: FXByteBuffer) throws {
        let pb = try rawBytes.withUnsafeReadableBytes {
            try FXPBCASObject(
                serializedBytes: Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!),
                    count: $0.count, deallocator: .none))
        }
        let refs = pb.refs
        var data = FXByteBufferAllocator().buffer(capacity: pb.data.count)
        data.writeBytes(pb.data)
        self.init(refs: refs, data: data)
    }

    public func toBytes(into buffer: inout FXByteBuffer) throws {
        buffer.writeBytes(try self.toData())
    }

}
