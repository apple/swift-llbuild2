// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

/// LLBCodables are designed to receive the full bytes when decoding, instead of the Foundation.Codable model where it
/// receives a support structure from which to read keyed data. Such systems imply that the nested structures should
/// also conform to the Codable APIs. In this case, the types conforming to LLBCodable can choose which serialization
/// strategy to use, so the type chooses whether to use JSONEncoder or SwiftProtobuf, for examples.

public enum LLBCodableError: Error {
    case unknownError(String)
}

/// Convenience protocol for types that support coding and decoding.
public typealias LLBCodable = LLBEncodable & LLBDecodable

/// Protocol for encoding support from a type.
public protocol LLBEncodable {
    func encode() throws -> LLBByteBuffer
}

/// Protocol for decoding support from a type.
public protocol LLBDecodable {
    init(from bytes: LLBByteBuffer) throws
}
