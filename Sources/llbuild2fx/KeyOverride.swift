// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public protocol FXKeyOverrideProtocol: Sendable {
    var keyTypeIdentifier: ObjectIdentifier { get }
    func callAsFunction(_ key: Any) async throws -> Any
}

public final class FXKeyOverrideRegistry: Sendable {
    private let overrides: [ObjectIdentifier: any FXKeyOverrideProtocol]

    public init(_ overrides: [any FXKeyOverrideProtocol]) {
        var dict = [ObjectIdentifier: any FXKeyOverrideProtocol]()
        for override in overrides {
            dict[override.keyTypeIdentifier] = override
        }
        self.overrides = dict
    }

    public func findOverride(for keyType: Any.Type) -> (any FXKeyOverrideProtocol)? {
        return overrides[ObjectIdentifier(keyType)]
    }
}
