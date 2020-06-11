// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Crypto
import LLBBuildSystemProtocol

extension ConfigurationKey: LLBBuildKey {}
extension ConfigurationValue: LLBBuildValue {}

public protocol LLBConfigurationFragmentKey: LLBBuildKey, LLBPolymorphicCodable {}
public protocol LLBConfigurationFragment: LLBBuildValue, LLBPolymorphicCodable {}

public enum ConfigurationError: Error {
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
public extension ConfigurationKey {
    init(fragmentKeys: [LLBConfigurationFragmentKey] = []) throws {
        // Sort keys to create a deterministic key.
        var validKeys = [LLBAnyCodable]()
        try fragmentKeys.sorted {
            type(of: $0).polymorphicIdentifier < type(of: $1).polymorphicIdentifier
        }.forEach { fragmentKey in
            if let lastCodable = validKeys.last,
                  lastCodable.typeIdentifier == type(of: fragmentKey).polymorphicIdentifier {
                throw ConfigurationError.multipleFragmentKeys(String(describing: type(of: fragmentKey).polymorphicIdentifier))
            }
            validKeys.append(try LLBAnyCodable(from: fragmentKey))
        }
        self.fragmentKeys = validKeys
    }

    func get<C: LLBConfigurationFragmentKey>(_ type: C.Type = C.self) throws -> C {
        for anyFragmentKey in fragmentKeys {
            if anyFragmentKey.typeIdentifier == C.polymorphicIdentifier {
                let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(anyFragmentKey.serializedCodable))
                return try C.init(from: byteBuffer)
            }
        }

        throw ConfigurationError.missingFragmentKey(C.polymorphicIdentifier)
    }
}

// Convenience initializer.
extension ConfigurationValue {
    init(fragments: [LLBConfigurationFragment]) throws {
        self.fragments = try fragments.map { try LLBAnyCodable(from: $0 )}
    }

    func get<C: LLBConfigurationFragment>(_ type: C.Type = C.self) throws -> C {
        for anyFragment in fragments {
            if anyFragment.typeIdentifier == C.polymorphicIdentifier {
                let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(anyFragment.serializedCodable))
                return try C.init(from: byteBuffer)
            }
        }

        throw ConfigurationError.missingFragment(C.polymorphicIdentifier)
    }
}

extension ConfigurationKey {
    /// Registers a type as a LLBConfigurationFragmentKey. This is required in order for the type to be able to be
    /// decoded at runtime, since llbuild2 allows dynamic types for LLBConfigurationFragmentKeys.
    public static func register(fragmentKeyType: LLBConfigurationFragmentKey.Type) {
        LLBAnyCodable.register(type: fragmentKeyType)
    }
}

extension ConfigurationValue {
    /// Registers a type as a LLBConfigurationFragment. This is required in order for the type to be able to be decoded
    /// at runtime, since llbuild2 allows dynamic types for LLBConfigurationFragments.
    public static func register(fragmentType: LLBConfigurationFragment.Type) {
        LLBAnyCodable.register(type: fragmentType)
    }
}

final class ConfigurationFunction: LLBBuildFunction<ConfigurationKey, ConfigurationValue> {
    override func evaluate(key: ConfigurationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ConfigurationValue> {
        do {
            let fragmentKeys: [LLBConfigurationFragmentKey] = try key.fragmentKeys.map { (anyFragmentKey: LLBAnyCodable) in
                guard let fragmentKeyType = anyFragmentKey.registeredType() as? LLBConfigurationFragmentKey.Type else {
                    throw ConfigurationError.unexpectedType(
                            "Could not find type for \(anyFragmentKey.typeIdentifier), did you forget to register it?"
                    )
                }
                let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(anyFragmentKey.serializedCodable))
                return try fragmentKeyType.init(from: byteBuffer)
            }

            // Request all of the fragment keys to convert them into fragments to be added to the configuration.
            return fi.request(fragmentKeys).flatMapThrowing { fragments in
                try fragments.map { maybeFragment in
                    guard let fragment = maybeFragment as? LLBConfigurationFragment else {
                        throw ConfigurationError.unexpectedType("Expected an LLBConfigurationFragment but got \(String(describing: type(of: maybeFragment)))")
                    }
                    return fragment
                }
            }.flatMapThrowing { (fragments: [LLBConfigurationFragment]) -> ConfigurationValue in
                var configurationValue = try ConfigurationValue(fragments: fragments)

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
            return fi.group.next().makeFailedFuture(ConfigurationError.unexpectedError(error))
        }
    }
}
