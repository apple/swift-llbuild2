// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import Foundation

/// Convenience implementation for LLBConfigurationFragmentKey that conform to Codable
extension LLBArtifact: Codable {
    convenience public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(serializedData: container.decode(Data.self))
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.serializedData())
    }
}

/// Convenience implementation for LLBConfigurationFragmentKey that conform to Codable
extension LLBConfigurationFragmentKey where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBConfigurationFragmentKey that conform to Codable
extension LLBConfigurationFragmentKey where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for LLBConfigurationFragment that conform to Codable
extension LLBConfigurationFragment where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBConfigurationFragment that conform to Codable
extension LLBConfigurationFragment where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation for LLBProviders that conform to Codable
extension LLBProvider where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for LLBProviders that conform to Codable
extension LLBProvider where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}

/// Convenience implementation of LLBProviderMap as Codable for use by clients of llbuild2.
extension LLBProviderMap: Codable {
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(serializedData: container.decode(Data.self))
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.serializedData())
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable
extension LLBConfiguredTarget where Self: Encodable {
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        let data = try JSONEncoder().encode(self)
        buffer.writeBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable
extension LLBConfiguredTarget where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}
