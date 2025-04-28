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
