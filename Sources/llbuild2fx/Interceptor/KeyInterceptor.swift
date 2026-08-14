// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

/// An interceptor for FXKey.
public protocol FXKeyInterceptor: Sendable {
    /// Intercepts a key computation.
    ///
    /// This intercepts a call to ``FXKey/computeValue(_:_:)``. It only fires when the key is
    /// actually computed, not on cache hit.
    ///
    /// - Parameters:
    ///   - input: The key and context of the computation to evaluate.
    ///   - next: A closure to invoke the next interceptor in the chain.
    func computeValue<K: FXKey>(
        input: FXKeyInput<K>,
        next: (FXKeyInput<K>) async throws -> K.ValueType
    ) async throws -> K.ValueType
}

extension FXKeyInterceptor {
    public func computeValue<K: FXKey>(
        input: FXKeyInput<K>,
        next: (FXKeyInput<K>) async throws -> K.ValueType
    ) async throws -> K.ValueType {
        return try await next(input)
    }
}

/// Placeholder for FXInterceptor conformers that don't have a key interceptor.
public struct FXForwardingKeyInterceptor: FXKeyInterceptor {
    public init() {}
}

/// Inputs to a key.
public struct FXKeyInput<K: FXKey>: Sendable {
    /// The key that was requested.
    public let key: K

    /// The context for the computation.
    public var context: Context

    public init(key: K, context: Context) {
        self.key = key
        self.context = context
    }
}
