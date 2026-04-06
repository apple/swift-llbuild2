// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Dispatch
import NIOConcurrencyHelpers
import NIOCore

/// Deduplicate results of multiple requests for the same value.
///
/// This cache coalesces requests and avoids re-obtaining values multiple times.
package class FXFutureDeduplicator<Key: Hashable, Value> {
    /// The futures group.
    @usableFromInline
    internal let group: FXFuturesDispatchGroup

    /// When to expire results that couldn't be resolved in time.
    @usableFromInline
    internal let partialResultExpiration: DispatchTimeInterval

    /// Protect shared inFlightRequests.
    @usableFromInline
    internal let lock = NIOConcurrencyHelpers.NIOLock()

    /// The mapping of the keys currently being resolved.
    @usableFromInline
    internal var inFlightRequests = [Key: (result: FXPromise<Value>, expires: DispatchTime)]()

    /// Override expiration of erroneous result by the error type.
    /// By default erroneous results expire immediately.
    @usableFromInline
    internal var expirationInterval: (_ for: Swift.Error) -> DispatchTimeInterval?

    /// Return the number of entries in the cache.
    package var inFlightRequestCount: Int {
        return lock.withLock { inFlightRequests.count }
    }

    package init(
        group: FXFuturesDispatchGroup,
        partialResultExpiration: DispatchTimeInterval = .seconds(300),
        expirationIntervalOverride: @escaping (_ for: Swift.Error) -> DispatchTimeInterval? = { _ in
            nil
        }
    ) {
        self.group = group
        self.partialResultExpiration = partialResultExpiration
        self.expirationInterval = expirationIntervalOverride
    }

    /// Debug expiration time.
    package func getExpiration(for key: Key) -> DispatchTime? {
        return lock.withLock { inFlightRequests[key]?.expires }
    }

    // Check if we already have this value, under lock.
    @inlinable
    internal func lockedCacheGet(key: Key) -> FXFuture<Value>? {
        // Override if needed.
        return nil
    }

    // Cache the value, under lock.
    @inlinable
    internal func lockedCacheSet(_ key: Key, _ future: FXFuture<Value>) {
        // Override if needed.
    }

    /// Opportunistically extract in-flight future to possibly piggy back on
    /// an existing future that is going on without initiating a new value
    /// resolution.
    /// - Returns:
    ///     `nil` if the value future doesn't exist in flight.
    ///     _future_,  if the value is being computed.
    @inlinable
    package subscript(_ key: Key) -> FXFuture<Value>? {
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
    package func value(for key: Key, with resolver: (Key) -> FXFuture<Value>) -> FXFuture<Value> {
        let now = DispatchTime.now()

        let (future, createdPromise): (FXFuture<Value>, FXPromise<Value>?) = lock.withLock {
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

    @inlinable
    package func values(for keys: [Key], with resolver: ([Key]) -> FXFuture<[Value]>) -> [FXFuture<
        Value
    >] {
        let (rv, created, promises): ([FXFuture<Value>], [Key], [FXPromise<Value>]) =
            lock.withLock {
                let now = DispatchTime.now()

                var rv = [FXFuture<Value>]()
                var created = [Key]()
                var promises = [FXPromise<Value>]()
                let maxResultCount = keys.count
                rv.reserveCapacity(maxResultCount)
                created.reserveCapacity(maxResultCount)
                promises.reserveCapacity(maxResultCount)

                for key in keys {
                    if let valueFuture = lockedCacheGet(key: key) {
                        rv.append(valueFuture)
                        continue
                    }

                    if let (resultPromise, expires) = inFlightRequests[key] {
                        if expires >= now {
                            rv.append(resultPromise.futureResult)
                            continue
                        }
                    }

                    // Stop deduplicating requests after a long-ish timeout,
                    // just in case there is a particularly long CAS lag.
                    let expires = now + partialResultExpiration

                    // Cache for future use.
                    let promise = self.group.next().makePromise(of: Value.self)
                    self.inFlightRequests[key] = (promise, expires)
                    rv.append(promise.futureResult)
                    created.append(key)
                    promises.append(promise)
                }

                return (rv, created, promises)
            }

        // If the promise was created, fetch from the database.
        guard created.count > 0 else {
            return rv
        }

        resolver(created).map { results in
            self.lock.withLockVoid {
                for idx in 0..<created.count {
                    let key = created[idx]
                    let promise = promises[idx]
                    guard self.inFlightRequests[key]?.result.futureResult === promise.futureResult
                    else {
                        continue
                    }
                    // Resolved, done.
                    self.inFlightRequests[key] = nil
                }
                for (key, promise) in zip(created, promises) {
                    self.lockedCacheSet(key, promise.futureResult)
                }
            }
            for (promise, result) in zip(promises, results) {
                promise.succeed(result)
            }
        }.whenFailure { error in
            let now = DispatchTime.now()
            let expires: DispatchTimeInterval? = self.expirationInterval(error)
            self.lock.withLockVoid {
                for (key, promise) in zip(created, promises) {
                    guard self.inFlightRequests[key]?.result.futureResult === promise.futureResult
                    else {
                        continue
                    }
                    if let interval = expires {
                        self.inFlightRequests[key] = (promise, now + interval)
                    } else {
                        self.inFlightRequests[key] = nil
                    }
                }
            }

            for promise in promises {
                promise.fail(error)
            }
        }

        return rv
    }
}
