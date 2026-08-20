// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

// Vendored from `TSCUtility.Context` (apple/swift-tools-support-core), which was removed
// from that package in 0.8.0 without replacement.

/// An untyped, per-key value bag threaded through the engine to carry ambient
/// state (logging, deadlines, cancellation, etc.) without growing every API's
/// parameter list.
public struct Context {
    private var backing: [ObjectIdentifier: Any] = [:]

    public init() {}

    public init(dictionaryLiteral keyValuePairs: (ObjectIdentifier, Any)...) {
        self.backing = Dictionary(uniqueKeysWithValues: keyValuePairs)
    }

    public subscript<Value>(key: ObjectIdentifier, as type: Value.Type = Value.self) -> Value? {
        get {
            return self.backing[key] as? Value
        }
        set {
            self.backing[key] = newValue
        }
    }
}

extension Context: @unchecked Sendable {}
