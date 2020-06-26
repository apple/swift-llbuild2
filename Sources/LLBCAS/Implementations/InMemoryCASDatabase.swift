// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIOConcurrencyHelpers
import TSCUtility

import LLBSupport


/// A simple in-memory implementation of the `LLBCASDatabase` protocol.
public final class LLBInMemoryCASDatabase {
    /// The content.
    private var content = [LLBDataID: LLBCASObject]()

    /// Threads capable of running futures.
    public var group: LLBFuturesDispatchGroup

    /// The lock protecting content.
    let lock = NIOConcurrencyHelpers.Lock()

    /// The total number of data bytes in the database (this does not include the size of refs).
    public var totalDataBytes: Int {
        return lock.withLock { _totalDataBytes }
    }
    fileprivate var _totalDataBytes: Int = 0

    /// Create an in-memory database.
    public init(group: LLBFuturesDispatchGroup) {
        self.group = group
    }

    /// Delete the data in the database.
    /// Intentionally not exposed via the CASDatabase protocol.
    public func delete(_ id: LLBDataID, recursive: Bool) -> LLBFuture<Void> {
        lock.withLockVoid {
            unsafeDelete(id, recursive: recursive)
        }
        return group.next().makeSucceededFuture(())
    }
    private func unsafeDelete(_ id: LLBDataID, recursive: Bool) {
        guard let object = content[id] else {
            return
        }
        _totalDataBytes -= object.data.readableBytes

        guard recursive else {
            return
        }

        for ref in object.refs {
            unsafeDelete(ref, recursive: recursive)
        }
    }
}

extension LLBInMemoryCASDatabase: LLBCASDatabase {
    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        return group.next().makeSucceededFuture(LLBCASFeatures(preservesIDs: true))
    }

    public func contains(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<Bool> {
        let result = lock.withLock { self.content.index(forKey: id) != nil }
        return group.next().makeSucceededFuture(result)
    }

    public func get(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<LLBCASObject?> {
        let result = lock.withLock { self.content[id] }
        return group.next().makeSucceededFuture(result)
    }

    public func identify(refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        return group.next().makeSucceededFuture(LLBDataID(blake3hash: data, refs: refs))
    }

    public func put(refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        return put(knownID: LLBDataID(blake3hash: data, refs: refs), refs: refs, data: data, ctx)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        lock.withLockVoid {
            guard content[id] == nil else {
                assert(content[id]?.data == data, "put data for id doesn't match")
                return
            }
            _totalDataBytes += data.readableBytes
            content[id] = LLBCASObject(refs: refs, data: data)
        }
        return group.next().makeSucceededFuture(id)
    }
}

public struct LLBInMemoryCASDatabaseScheme: LLBCASDatabaseScheme {
    public static let scheme = "mem"

    public static func isValid(host: String?, port: Int?, path: String, query: String?) -> Bool {
        return host == nil && port == nil && path == "" && query == nil
    }

    public static func open(group: LLBFuturesDispatchGroup, url: Foundation.URL) throws -> LLBCASDatabase {
        return LLBInMemoryCASDatabase(group: group)
    }
}
