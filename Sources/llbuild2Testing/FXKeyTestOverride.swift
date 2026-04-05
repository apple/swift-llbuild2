// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2fx

public struct FXKeyTestOverride<K: FXKey>: FXKeyOverrideProtocol {
    public let keyTypeIdentifier: ObjectIdentifier
    private let handler: @Sendable (K) async throws -> K.ValueType

    public init(_ keyType: K.Type, handler: @escaping @Sendable (K) async throws -> K.ValueType) {
        self.keyTypeIdentifier = ObjectIdentifier(keyType)
        self.handler = handler
    }

    public func callAsFunction(_ key: Any) async throws -> Any {
        guard let typedKey = key as? K else {
            throw FXError.invalidValueType("FXKeyTestOverride expected \(K.self) but got \(type(of: key))")
        }
        return try await handler(typedKey)
    }
}
