// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

/// Provides interceptors for an FXEngine.
///
/// Interceptors are called when the `FXEngine` performs certain operations, making it possible to
/// inject tracing, statistics, etc.
///
/// When multiple interceptors are provided to the engine, the wrapping occurs from left to right:
/// if the interceptors are [A, B], the result will be A(B(operation())).
public protocol FXInterceptor: Sendable {
    associatedtype KeyInterceptor: FXKeyInterceptor = FXForwardingKeyInterceptor

    /// An interceptor for FXKey.
    var keyInterceptor: KeyInterceptor? { get }
}

extension FXInterceptor {
    public var keyInterceptor: KeyInterceptor? { nil }
}
