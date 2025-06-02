// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public enum FXError: Swift.Error {
    case nonCallableKey
    case cycleDetected([FXRequestKey])

    case valueComputationError(keyPrefix: String, key: String, error: Swift.Error, requestedCacheKeyPaths: FXSortedSet<String>)
    case keyEncodingError(keyPrefix: String, encodingError: Swift.Error, underlyingError: Swift.Error)

    case missingRequiredCacheEntry(cachePath: String)
    case unexpressedKeyDependency(from: String, to: String)
    case executorCannotSatisfyRequirements
    case noExecutable
    case invalidValueType(String)
    case unexpectedKeyType(String)
    case inconsistentValue(String)
    case resourceNotFound(ResourceKey)
}

func unwrapFXError(_ error: Swift.Error) -> Swift.Error {
    guard case FXError.valueComputationError(
         keyPrefix: _,
         key: _,
         error: let underlyingError,
         requestedCacheKeyPaths: _
    ) = error else {
        return error
    }

    // May need to continue unwrapping
    return unwrapFXError(underlyingError)
}

/// Overall result that this error implies
public enum FXErrorStatus: Sendable {
    /// A non-terminal error
    case warning

    /// A generic terminal error
    case failure

    /// An implementation specific string
    case custom(String)
}

public enum FXErrorClassification: String, Sendable {
    /// A user caused failure (such as bad input, config, etc.)
    case user

    /// An internal failure
    case infrastructure
}

public struct FXErrorDetails: Sendable {
    public var status: FXErrorStatus
    public var classification: FXErrorClassification
    public var details: String

    public init(
        status: FXErrorStatus,
        classification: FXErrorClassification,
        details: String
    ) {
        self.status = status
        self.classification = classification
        self.details = details
    }
}

public protocol FXErrorClassifier {
    func tryClassifyError(_ error: Swift.Error) -> FXErrorDetails?
}
