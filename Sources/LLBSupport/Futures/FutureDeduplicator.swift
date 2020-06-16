// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch

import NIOConcurrencyHelpers


/// Deduplicate results of multiple requests for the same value.
///
/// This cache coalesces requests and avoids re-obtaining values multiple times.
public class LLBFutureDeduplicator<Key: Hashable, Value> {
    /// The futures group.
    @usableFromInline
    internal let group: LLBFuturesDispatchGroup

    /// When to expire results that couldn't be resolved in time.
    @usableFromInline
    internal let partialResultExpiration: DispatchTimeInterval

    /// Protect shared inFlightRequests.
    @usableFromInline
    internal let lock = NIOConcurrencyHelpers.Lock()

    /// The mapping of the keys currently being resolved.
    @usableFromInline
    internal var inFlightRequests = [Key: (result: LLBPromise<Value>, expires: DispatchTime)]()

    /// Override expiration of erroneous result by the error type.
    /// By default erroneous results expire immediately.
    @usableFromInline
    internal var expirationInterval: (_ for: Swift.Error) -> DispatchTimeInterval?

    /// Return the number of entries in the cache.
    public var inFlightRequestCount: Int {
        get { return lock.withLock { inFlightRequests.count } }
    }

    public init(group: LLBFuturesDispatchGroup, partialResultExpiration: DispatchTimeInterval = .seconds(300), expirationIntervalOverride: @escaping (_ for: Swift.Error) -> DispatchTimeInterval? = { _ in nil }) {
        self.group = group
        self.partialResultExpiration = partialResultExpiration
        self.expirationInterval = expirationIntervalOverride
    }

    /// Debug expiration time.
    public func getExpiration(for key: Key) -> DispatchTime? {
        return lock.withLock { inFlightRequests[key]?.expires }
    }

    // Check if we already have this value, under lock.
    @inlinable
    internal func lockedCacheGet(key: Key) -> LLBFuture<Value>? {
        // Override if needed.
        return nil
    }

    // Cache the value, under lock.
    @inlinable
    internal func lockedCacheSet(_ key: Key, _ future: LLBFuture<Value>) {
        // Override if needed.
    }

    /// Opportunistically extract in-flight future to possibly piggy back on
    /// an existing future that is going on without initiating a new value
    /// resolution.
    /// - Returns:
    ///     `nil` if the value future doesn't exist in flight.
    ///     _future_,  if the value is being computed.
    @inlinable
    public subscript(_ key: Key) -> LLBFuture<Value>? {
        get {
            let now = DispatchTime.now()
            return lock.withLock {
                if let valueFuture = lockedCacheGet(key: key) {
                    return valueFuture
                }
                guard let (valuePromise, expires) = inFlightRequests[key] else {
                    return nil
                }
                guard now < expires else {
                    inFlightRequests[key] = nil
                    return nil
                }
                return valuePromise.futureResult
            }
        }
    }

    @inlinable
    public func value(for key: Key, with resolver: (Key) -> LLBFuture<Value>) -> LLBFuture<Value> {
        let now = DispatchTime.now()

        let (future, createdPromise): (LLBFuture<Value>, LLBPromise<Value>?) = lock.withLock {
            if let valueFuture = lockedCacheGet(key: key) {
                return (valueFuture, nil)
            }

            if let (valuePromise, expires) = inFlightRequests[key] {
                guard expires < now else {
                    return (valuePromise.futureResult, nil)
                }
            }

            // Stop deduplicating requests after a long-ish timeout,
            // just in case there is a particularly long CAS lag.
            let expires = now + partialResultExpiration

            // Cache for future use.
            let promise = self.group.next().makePromise(of: Value.self)
            self.inFlightRequests[key] = (promise, expires)
            return (promise.futureResult, promise)
        }

        // If the promise was not created, return whatever's in the future.
        guard let promise = createdPromise else {
            return future
        }

        resolver(key).map { result in
            self.lock.withLockVoid {
                guard self.inFlightRequests[key]?.result.futureResult === future else {
                    return
                }
                // Resolved, done.
                self.inFlightRequests[key] = nil
                self.lockedCacheSet(key, future)
            }
            return result
        }.flatMapErrorThrowing { error in
            let expires: DispatchTimeInterval? = self.expirationInterval(error)
            self.lock.withLockVoid {
                guard self.inFlightRequests[key]?.result.futureResult === future else {
                    return
                }
                if let interval = expires {
                    self.inFlightRequests[key] = (promise, now + interval)
                } else {
                    self.inFlightRequests[key] = nil
                }
            }
            throw error
        }.cascade(to: promise)

        return promise.futureResult
    }
}
