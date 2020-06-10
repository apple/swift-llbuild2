// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Foundation

/// Protocol that configured target instances must conform to.
public protocol ConfiguredTarget: LLBPolymorphicCodable {}

/// Convenience implementation for ConfiguredTargets that conform to Codable
extension ConfiguredTarget where Self: Encodable {
    public func encode() throws -> LLBByteBuffer {
        let data = try JSONEncoder().encode(self)
        return LLBByteBuffer.withBytes(ArraySlice<UInt8>(data))
    }
}

/// Convenience implementation for ConfiguredTargets that conform to Codable
extension ConfiguredTarget where Self: Decodable {
    public init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }
}


/// Protocol definition for a delegate that provides an LLBFuture<ConfiguredTarget> instance.
public protocol LLBConfiguredTargetDelegate {

    /// Returns a future with a ConfiguredTarget for the given ConfiguredTargetKey. This method will be invoked inside
    /// of a ConfiguredTargetFunction evaluation, so the invocation of this method will only happen once per
    /// ConfiguredTargetKey. There is no need to implement additional caching inside of the delegate method.
    /// The LLBBuildFunctionInterface is also provided to allow requesting additional keys during evaluation. Any custom
    /// function that is needed to evaluate a ConfiguredTarget will need to be implemented by the client and returned
    /// through the LLBBuildFunctionLookupDelegate implementation.
    func configuredTarget(for key: ConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) throws -> LLBFuture<ConfiguredTarget>
}