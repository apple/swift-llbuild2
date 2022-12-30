// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBBuildSystem
import Foundation
import llbuild2
import NIOCore
import SwiftProtobuf

// This file is a collection of extensions that make Codable adoption easier for
// the LLBBuildSystem types, to avoid having to implement codable for each of
// the types. Performance of Codable is not that great, so we might need to find
// a way to allow easy serialization/deserialization for client types.

/// Convenience implementation for LLBConfigurationFragmentKey that conform to Codable.
extension LLBConfigurationFragmentKey where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBConfigurationFragmentKey that conform to Codable.
extension LLBConfigurationFragmentKey where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for LLBConfigurationFragment that conform to Codable.
extension LLBConfigurationFragment where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBConfigurationFragment that conform to Codable.
extension LLBConfigurationFragment where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for LLBProviders that conform to Codable.
extension LLBProvider where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBProviders that conform to Codable.
extension LLBProvider where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable.
extension LLBConfiguredTarget where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable.
extension LLBConfiguredTarget where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for keys that extend SwiftProtobuf.Message.
extension LLBBuildKey where Self: Encodable {
    public static var identifier: LLBBuildKeyIdentifier {
        return String(describing: Self.self)
    }
    
    public var stableHashValue: LLBDataID {
        let data = try! JSONEncoder().encode(self)
        return LLBDataID(blake3hash: ArraySlice(data))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable.
extension LLBBuildValue where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable.
extension LLBBuildValue where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
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
        try self.init(serializedData: container.decode(Data.self))
    }
}

// Convenience constraint so that SwiftProtobuf serialization is preferred over Codable.
extension LLBSerializableIn where Self: Decodable, Self: SwiftProtobuf.Message {
    public init(from bytes: LLBByteBuffer) throws {
        let data = Data(bytes.readableBytesView)
        self = try Self.init(serializedData: data)
    }
}

// Convenience constraint so that SwiftProtobuf serialization is preferred over Codable.
extension LLBSerializableOut where Self: Encodable, Self: SwiftProtobuf.Message {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeBytes(try self.serializedData())
    }
}

// Convenience extension of generally used SwiftProtobuf based types from the LLBBuildSystem target.
extension LLBArtifact: LLBSerializable, Codable {}
extension LLBProviderMap: LLBSerializable, Codable {}
extension LLBLabel: LLBSerializable, Codable {}
