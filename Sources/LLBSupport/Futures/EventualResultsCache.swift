// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


/// Cache of keys to eventually obtainable values.
///
/// This cache coalesces requests and avoids re-obtaining values multiple times.
public final class LLBEventualResultsCache<Key: Hashable, Value>: LLBFutureDeduplicator<Key, Value> {
    /// The already cached keys.
    @usableFromInline
    internal var storage = [Key: LLBFuture<Value>]()

    /// Return the number of entries in the cache.
    @inlinable
    public var count: Int {
        get { return lock.withLock { storage.count } }
    }

    @inlinable
    override internal func lockedCacheGet(key: Key) -> LLBFuture<Value>? {
        return storage[key]
    }

    @inlinable
    override internal func lockedCacheSet(_ key: Key, _ future: LLBFuture<Value>) {
        storage[key] = future
    }

    @inlinable
    public override subscript(_ key: Key) -> LLBFuture<Value>? {
        get { return super[key] }
        set { lock.withLockVoid { storage[key] = newValue } }
    }
}
