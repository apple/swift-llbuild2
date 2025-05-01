// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

extension FXVersioning {
    public func getConfigurationInputs(_ ctx: Context) -> KeyConfiguration<Self> {
        KeyConfiguration(inputs: ctx.fxConfigurationInputs)
    }
}

public typealias FXConfigurationInputs = [String: Encodable]

extension Context {
    public var fxConfigurationInputs: FXConfigurationInputs {
        get {
            return (self[ObjectIdentifier(FXConfigurationInputs.self), as: FXConfigurationInputs.self]) ?? [:]
        }
        set {
            self[ObjectIdentifier(FXConfigurationInputs.self)] = newValue
        }
    }
}

/// KeyConfiguration represents a grab-bag of information that could inform various steps of
/// the build. For example, it's the ideal container for information from an A/B testing or
/// feature-flag system. It ensures that only the configuration explicitly requested by a
/// given FXKey is visible to that key, and that the cache key is set up appropriately
/// so that if a downstream key starts requesting more configuration, we actually recalculate
/// appropriately.
public final class KeyConfiguration<K: FXVersioning>: Encodable {
    private let inputs: FXConfigurationInputs
    private let allowedInputs: FXSortedSet<String>

    init(inputs: FXConfigurationInputs) {
        self.inputs = inputs
        self.allowedInputs = Self.resolveKeys(K.configurationKeys, universe: Array(inputs.keys))
    }

    static func resolveKeys(_ keys: [ConfigurationKey], universe: [String]) -> FXSortedSet<String> {
        return FXSortedSet(keys.reduce(into: [String](), { (result, key) in
            switch key {
                case let .literal(val):
                    result.append(val)
                case let .prefix(prefix):
                    result.append(contentsOf: universe.filter { $0.hasPrefix(prefix)} )
            }
        }))
    }

    public func get<T>(_ key: String) -> T? {
        if !allowedInputs.contains(key) {
            return nil
        }
        return inputs[key] as? T
    }

    public func encode(to encoder: Encoder) throws {
        let allPossibleAllowed = Self.resolveKeys(Array(K.aggregatedConfigurationKeys), universe: Array(self.inputs.keys))

        try encoder.fxEncodeHash(of: try inputs.filter{ (k, _) in allPossibleAllowed.contains(k) }.mapValues { (val: Encodable) -> String in try val.fxEncodeJSON() })
    }

    func isNoop() -> Bool {
        return self.allowedInputs.isEmpty && K.aggregatedConfigurationKeys.allSatisfy({ key in
            switch key {
                case .literal(_):
                    return false
                case let .prefix(prefix):
                    return self.inputs.keys.filter { $0.hasPrefix(prefix) }.isEmpty
            }
        })
    }
}
