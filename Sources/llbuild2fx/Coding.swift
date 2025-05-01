// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import SwiftProtobuf

public struct FXEncoder {
    private let encoder: JSONEncoder

    public init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
}

public struct FXDecoder {
    private let decoder: JSONDecoder

    public init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

extension Encoder {
    public func fxEncodeHash<V: Encodable>(of value: V) throws {
        let data = try FXEncoder().encode(value)
        try encodeHash(of: ArraySlice<UInt8>(data))
    }

    func encodeHash(of data: ArraySlice<UInt8>) throws {
        var container = singleValueContainer()

        let hash = LLBDataID(blake3hash: data)
        // We don't need the whole ID to avoid key collisions.
        let str = ArraySlice(hash.bytes.dropFirst().prefix(9)).base64URL()
        try container.encode(str)
    }
}

extension Encodable {
    public func fxEncodeJSON() throws -> String {
        let encoder = FXEncoder()
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}

extension Encodable where Self: SwiftProtobuf.Message {
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.serializedData())
    }
}

extension Decodable where Self: SwiftProtobuf.Message {
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(serializedBytes: container.decode(Data.self))
    }
}

// Convenience constraint so that SwiftProtobuf serialization is preferred over Codable.
extension LLBSerializableIn where Self: Decodable, Self: SwiftProtobuf.Message {
    public init(from bytes: LLBByteBuffer) throws {
        let data = Data(bytes.readableBytesView)
        self = try Self.init(serializedBytes: data)
    }
}

// Convenience constraint so that SwiftProtobuf serialization is preferred over Codable.
extension LLBSerializableOut where Self: Encodable, Self: SwiftProtobuf.Message {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeBytes(try self.serializedData())
    }
}
