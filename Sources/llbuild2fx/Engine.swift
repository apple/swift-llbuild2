// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch
import Logging
import NIOCore
import TSFFutures
import Tracing
import Instrumentation

public protocol FXStablyHashable {
    var stableHashValue: LLBDataID { get }
}

public protocol FXRequestKey: FXStablyHashable {
    func hash(into hasher: inout Hasher)
    var hashValue: Int { get }

    /// Use for debugging purposes, should not be invoked by the engine unless the logger is configured for the trace
    /// level.
    func logDescription() -> String
}

public extension FXRequestKey {
    /// Default implementation for all keys. Keys can implement their own method if they want to display more relevant
    /// information.
    func logDescription() -> String {
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
    static func ==(lhs: HashableKey, rhs: HashableKey) -> Bool {
        return lhs.key.hashValue == rhs.key.hashValue
    }
}

internal protocol CallableKey {
    func function() -> GenericFunction
}
internal protocol GenericFunction {
    func compute(key: FXRequestKey, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<FXResult>
}

internal class FunctionInterface {
    @usableFromInline
    let engine: FXEngine

    let key: FXRequestKey

    /// The function execution cache
    @inlinable
    public var functionCache: FXFunctionCache { return engine.cache }

    init(engine: FXEngine, key: FXRequestKey) {
        self.engine = engine
        self.key = key
    }

    public func request(_ key: FXRequestKey, _ ctx: Context) -> LLBFuture<FXResult> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return ctx.group.next().makeFailedFuture(error)
        }
        let future = engine.build(key: key, ctx)
        future.whenComplete { _ in
            self.engine.keyDependencyGraph.removeEdge(from: self.key, to: key)
        }
        return future
    }

    public func request<V: FXResult>(_ key: FXRequestKey, as type: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
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

public final class FXEngine {
    private let group: LLBFuturesDispatchGroup
    private let db: LLBCASDatabase
    @usableFromInline internal let cache: FXFunctionCache
    private let executor: FXExecutor
    private let stats: FXBuildEngineStats
    private let logger: Logger?

    fileprivate let pendingResults: LLBEventualResultsCache<HashableKey, FXResult>
    fileprivate let keyDependencyGraph = FXKeyDependencyGraph()

    public init(
        group: LLBFuturesDispatchGroup,
        db: LLBCASDatabase,
        functionCache: FXFunctionCache?,
        executor: FXExecutor,
        stats: FXBuildEngineStats? = nil,
        logger: Logger? = nil,
        partialResultExpiration: DispatchTimeInterval = .seconds(300)
    ) {
        self.group = group
        self.db = db
        self.cache = functionCache ?? FXInMemoryFunctionCache(group: group)
        self.executor = executor
        self.stats = stats ?? .init()
        self.logger = logger

        self.pendingResults = LLBEventualResultsCache<HashableKey, FXResult>(group: group, partialResultExpiration: partialResultExpiration)
    }

    /// Populate context with engine provided values
    private func engineContext(_ ctx: Context) -> Context {
        var ctx = ctx
        ctx.group = self.group
        ctx.db = self.db

        ctx.fxExecutor = executor
        ctx.fxBuildEngineStats = stats

        if let logger = self.logger {
            ctx.logger = logger
        }

        return ctx
    }

    enum Error: Swift.Error {
        case noFXFunctionProvider(FXRequestKey)
        case invalidValueType(String)
    }

    internal func build(key: FXRequestKey, _ ctx: Context) -> LLBFuture<FXResult> {
        let ctx = engineContext(ctx)
        return self.pendingResults.value(for: HashableKey(key: key)) { _ in
            guard let ikey = key as? CallableKey else {
                fatalError("non-callable key type")
            }
            let fn = ikey.function()
            let fi = FunctionInterface(engine: self, key: key)
            return fn.compute(key: key, fi, ctx)
        }
    }

    internal func build<V: FXResult>(key: FXRequestKey, as: V.Type, _ ctx: Context) -> LLBFuture<V> {
        return self.build(key: key, ctx).flatMapThrowing {
            guard let value = $0 as? V else {
                throw Error.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }

    public func build<K: FXKey>(
        key: K,
        _ ctx: Context
    ) -> LLBFuture<K.ValueType> {
        let ctx = engineContext(ctx)
        return self.build(key: key.internalKey(ctx), as: InternalValue<K.ValueType>.self, ctx).map { internalValue in
            internalValue.value
        }
    }
}
