// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

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
