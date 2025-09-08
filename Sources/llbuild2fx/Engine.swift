// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch
import Foundation
import Instrumentation
import Logging
import NIOCore
@preconcurrency import TSFFutures
import Tracing

public protocol FXStablyHashable: Sendable {
    var stableHashValue: LLBDataID { get }
}

public protocol FXRequestKey: FXStablyHashable {
    func hash(into hasher: inout Hasher)
    var hashValue: Int { get }

    /// Use for debugging purposes, should not be invoked by the engine unless the logger is configured for the trace
    /// level.
    func logDescription() -> String
}

extension FXRequestKey {
    /// Default implementation for all keys. Keys can implement their own method if they want to display more relevant
    /// information.
    public func logDescription() -> String {
        String(describing: type(of: self))
    }
}


public protocol FXResult: LLBCASObjectRepresentable {}

internal struct HashableKey {
    let key: FXRequestKey
}

extension HashableKey: Hashable {
    func hash(into hasher: inout Hasher) {
        key.hash(into: &hasher)
    }
    static func == (lhs: HashableKey, rhs: HashableKey) -> Bool {
        return lhs.key.hashValue == rhs.key.hashValue
    }
}

internal protocol CallableKey {
    func function() -> GenericFunction
}
internal protocol GenericFunction {
    func compute(key: FXRequestKey, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<FXResult>
}

internal final class FunctionInterface: Sendable {
    @usableFromInline
    let engine: FXEngine

    let key: FXRequestKey

    init(engine: FXEngine, key: FXRequestKey) {
        self.engine = engine
        self.key = key
    }

    func request<V: FXResult>(_ key: FXRequestKey, as type: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return ctx.group.next().makeFailedFuture(error)
        }
        let future = engine.build(key: key, as: type, ctx)
        future.whenComplete { _ in
            self.engine.keyDependencyGraph.removeEdge(from: self.key, to: key)
        }
        return future
    }
}

public typealias FXBuildID = Foundation.UUID

public final class FXEngine: Sendable {
    internal let group: LLBFuturesDispatchGroup
    internal let db: LLBCASDatabase
    @usableFromInline internal let cache: FXFunctionCache
    internal let resources: [ResourceKey: FXResource]
    internal let executor: FXExecutor
    internal let stats: FXBuildEngineStats
    internal let logger: Logger?

    internal let cacheRequestOnly: Bool

    fileprivate let pendingResults: LLBEventualResultsCache<HashableKey, FXResult>
    fileprivate let keyDependencyGraph = FXKeyDependencyGraph()

    public let buildID: FXBuildID

    public init(
        group: LLBFuturesDispatchGroup,
        db: LLBCASDatabase,
        functionCache: FXFunctionCache?,
        executor: FXExecutor,
        resources: [ResourceKey: FXResource] = [:],
        buildID: FXBuildID = FXBuildID(),
        stats: FXBuildEngineStats? = nil,
        logger: Logger? = nil,
        partialResultExpiration: DispatchTimeInterval = .seconds(300)
    ) {
        self.group = group
        self.db = db
        self.cache = functionCache ?? FXInMemoryFunctionCache(group: group)
        self.resources = resources
        self.executor = executor
        self.stats = stats ?? .init()
        self.logger = logger

        self.pendingResults = LLBEventualResultsCache<HashableKey, FXResult>(group: group, partialResultExpiration: partialResultExpiration)

        self.buildID = buildID

        var cacheRequestOnly = false
        for res in resources.values {
            if case .requestOnly = res.lifetime {
                cacheRequestOnly = true
                break
            }
        }
        self.cacheRequestOnly = cacheRequestOnly
    }

    /// Populate context with engine provided values
    private func engineContext(_ ctx: Context) -> Context {
        var ctx = ctx
        ctx.group = self.group
        ctx.db = self.db

        if let logger = self.logger {
            ctx.logger = logger
        }

        return ctx
    }

    internal func build(key: FXRequestKey, _ ctx: Context) -> LLBFuture<FXResult> {
        let ctx = engineContext(ctx)
        return self.pendingResults.value(for: HashableKey(key: key)) { _ in
            guard let ikey = key as? CallableKey else {
                return ctx.group.any().makeFailedFuture(FXError.nonCallableKey)
            }
            let fn = ikey.function()
            let fi = FunctionInterface(engine: self, key: key)
            return fn.compute(key: key, fi, ctx)
        }
    }

    internal func build<V: FXResult>(key: FXRequestKey, as: V.Type, _ ctx: Context) -> LLBFuture<V> {
        return self.build(key: key, ctx).flatMapThrowing {
            guard let value = $0 as? V else {
                throw FXError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }

    public func build<K: FXKey>(
        key: K,
        _ ctx: Context
    ) -> LLBFuture<K.ValueType> {
        let ctx = engineContext(ctx)
        return self.build(key: key.internalKey(self, ctx), as: InternalValue<K.ValueType>.self, ctx).map { internalValue in
            internalValue.value
        }
    }
}
