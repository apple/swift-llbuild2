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

extension FXError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .nonCallableKey:
            return "Non-callable key"
        case .cycleDetected(let keys):
            return "Cycle detected in dependency graph: \(keys)"
        case .valueComputationError(let keyPrefix, let key, let error, let requestedCacheKeyPaths):
            return "Value computation failed, key: \(keyPrefix), error: \(error)"
        case .keyEncodingError(let keyPrefix, let encodingError, let underlyingError):
            return "Key encoding error for \(keyPrefix), encoding error: \(encodingError), underlying error: \(underlyingError)"
        case .missingRequiredCacheEntry(let cachePath):
            return "Missing required cache entry: \(cachePath)"
        case .unexpressedKeyDependency(let from, let to):
            return "Unexpressed key dependency from \(from) to \(to)"
        case .executorCannotSatisfyRequirements:
            return "Executor cannot satisfy requirements"
        case .noExecutable:
            return "No executable found"
        case .invalidValueType(let message):
            return "Invalid value type: \(message)"
        case .unexpectedKeyType(let message):
            return "Unexpected key type: \(message)"
        case .inconsistentValue(let message):
            return "Inconsistent value: \(message)"
        case .resourceNotFound(let resourceKey):
            return "Resource not found: \(resourceKey)"
        }
    }
}

func unwrapFXError(_ error: Swift.Error) -> Swift.Error {
    guard
        case FXError.valueComputationError(
            keyPrefix: _,
            key: _,
            error: let underlyingError,
            requestedCacheKeyPaths: _
        ) = error
    else {
        return error
    }

    // May need to continue unwrapping
    return unwrapFXError(underlyingError)
}

/// Overall result that this error implies
public enum FXErrorStatus: Sendable, Equatable {
    /// A non-terminal error
    case warning

    /// A generic terminal error
    case failure

    /// An implementation specific string
    case custom(String)
}

public enum FXErrorClassification: String, Sendable, Equatable {
    /// A user caused failure (such as bad input, config, etc.)
    case user

    /// An internal failure
    case infrastructure
}

public struct FXErrorDetails: Sendable, Equatable {
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
