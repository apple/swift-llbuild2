// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Crypto

extension LLBConfigurationKey: LLBBuildKey {}
extension LLBConfigurationValue: LLBBuildValue {}

public protocol LLBConfigurationFragmentKey: LLBBuildKey, LLBPolymorphicSerializable {}
public protocol LLBConfigurationFragment: LLBBuildValue {}

public enum LLBConfigurationError: Error {
    /// Unexpected type when deserializing the configured target
    case unexpectedType(String)

    /// Unexpected error coming from the delegate implementation.
    case unexpectedError(Error)

    /// Thrown when there are multiple fragment keys being added to the key.
    case multipleFragmentKeys(String)

    /// Thrown when the requested fragment key is missing in the configuration key.
    case missingFragmentKey(String)

    /// Thrown when the requested fragment is missing in the configuration.
    case missingFragment(String)
}

// Convenience initializer.
public extension LLBConfigurationKey {
    init(fragmentKeys: [LLBConfigurationFragmentKey] = []) throws {
        // Sort keys to create a deterministic key.
        var validKeys = [LLBAnySerializable]()
        try fragmentKeys.sorted {
            type(of: $0).polymorphicIdentifier < type(of: $1).polymorphicIdentifier
        }.forEach { fragmentKey in
            if let lastCodable = validKeys.last,
                  lastCodable.typeIdentifier == type(of: fragmentKey).polymorphicIdentifier {
                throw LLBConfigurationError.multipleFragmentKeys(String(describing: type(of: fragmentKey).polymorphicIdentifier))
            }
            validKeys.append(try LLBAnySerializable(from: fragmentKey))
        }
        self.fragmentKeys = validKeys
    }

    func get<C: LLBConfigurationFragmentKey>(_ type: C.Type = C.self) throws -> C {
        for anyFragmentKey in fragmentKeys {
            if anyFragmentKey.typeIdentifier == C.polymorphicIdentifier {
                let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(anyFragmentKey.serializedBytes))
                return try C.init(from: byteBuffer)
            }
        }

        throw LLBConfigurationError.missingFragmentKey(C.polymorphicIdentifier)
    }
}

// Convenience initializer.
extension LLBConfigurationValue {
    init(fragments: [LLBConfigurationFragment]) throws {
        self.fragments = try fragments.map { try LLBAnySerializable(from: $0 )}
    }

    func get<C: LLBConfigurationFragment>(_ type: C.Type = C.self) throws -> C {
        for anyFragment in fragments {
            if anyFragment.typeIdentifier == C.polymorphicIdentifier {
                let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(anyFragment.serializedBytes))
                return try C.init(from: byteBuffer)
            }
        }

        throw LLBConfigurationError.missingFragment(C.polymorphicIdentifier)
    }
}

final class ConfigurationFunction: LLBBuildFunction<LLBConfigurationKey, LLBConfigurationValue> {
    override func evaluate(key: LLBConfigurationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBConfigurationValue> {
        do {
            let fragmentKeys: [LLBConfigurationFragmentKey] = try key.fragmentKeys.map { (anyFragmentKey: LLBAnySerializable) in
                return try anyFragmentKey.deserialize(registry: fi.registry)
            }

            // Request all of the fragment keys to convert them into fragments to be added to the configuration.
            return fi.request(fragmentKeys).flatMapThrowing { fragments in
                try fragments.map { maybeFragment in
                    guard let fragment = maybeFragment as? LLBConfigurationFragment else {
                        throw LLBConfigurationError.unexpectedType("Expected an LLBConfigurationFragment but got \(String(describing: type(of: maybeFragment)))")
                    }
                    return fragment
                }
            }.flatMapThrowing { (fragments: [LLBConfigurationFragment]) -> LLBConfigurationValue in
                var configurationValue = try LLBConfigurationValue(fragments: fragments)

                // If there are no fragments, do not calculate a root.
                if fragments.count == 0 {
                    return configurationValue
                }

                // Calculate the hash of the configuration and create a root value for it.
                let hash = SHA256.hash(data: try! configurationValue.serializedData())
                configurationValue.root = hash.compactMap { String(format: "%02x", $0) }.joined()

                return configurationValue

            }
        } catch {
            return fi.group.next().makeFailedFuture(LLBConfigurationError.unexpectedError(error))
        }
    }
}
