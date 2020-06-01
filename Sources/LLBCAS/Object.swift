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
    /// The size of the object data.
    var size: Int {
        return data.readableBytes
    }
}


// MARK:- Codable support for CASObject -

extension LLBCASObject: Codable {
    private enum CodingKeys: String, CodingKey {
        case refs
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refs, forKey: .refs)
        try container.encode(data.getBytes(at: 0, length: data.readableBytes), forKey: .data)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.refs = try values.decode([LLBDataID].self, forKey: .refs)

        let bytes = try values.decode([UInt8].self, forKey: .data)

        let allocator = LLBByteBufferAllocator()
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        self.data = buffer
    }
}


// MARK:- CASObject <-> Proto -

public extension LLBCASObject {
    var asProto: LLBPBCASObject {
        var pb = LLBPBCASObject()
        pb.refs = self.refs.map { $0.asProto }
        pb.data = Data(self.data.getBytes(at: 0, length: self.data.readableBytes)!)
        return pb
    }
}

public extension LLBPBCASObject {
    init(_ casObject: LLBCASObject) {
        self = Self.with {
            $0.refs = casObject.refs.map { $0.asProto }
            $0.data = Data(casObject.data.getBytes(at: 0, length: casObject.data.readableBytes)!)
        }
    }
}

