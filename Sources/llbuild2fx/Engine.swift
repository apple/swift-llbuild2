// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import Dispatch
import Foundation
import Logging
import NIOCore

public protocol FXStablyHashable: Sendable {
    var stableHashValue: FXDataID { get }
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


public protocol FXResult: FXCASObjectRepresentable {}

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

internal protocol CallableKey<DataID> {
    associatedtype DataID: FXDataIDProtocol
    func function() -> any GenericFunction<DataID>
}
internal protocol GenericFunction<DataID> {
    associatedtype DataID: FXDataIDProtocol
    func compute(key: FXRequestKey, _ fi: FunctionInterface<DataID>, _ ctx: Context) -> FXFuture<InternalResult>
}

// MARK: - EngineInternalProtocol

/// Type-erased interface for engine internals. Used by ``FunctionInterface``
/// and ``FXFunctionInterface`` so they don't need to be generic over the
/// database type.
internal protocol EngineInternalProtocol<DataID>: AnyObject & Sendable {
    associatedtype DataID: FXDataIDProtocol
    func build(key: FXRequestKey, _ ctx: Context) -> FXFuture<InternalResult>
    func build<V: InternalResult>(key: FXRequestKey, as: V.Type, _ ctx: Context) -> FXFuture<V>
    var keyDependencyGraph: FXKeyDependencyGraph { get }
    func cacheContains(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) -> FXFuture<Bool>
    var stats: FXBuildEngineStats { get }
    var logger: Logger? { get }
    var keyOverrides: FXKeyOverrideRegistry? { get }
    var executor: FXExecutor { get }
    var resources: [ResourceKey: FXResource] { get }
    var cacheRequestOnly: Bool { get }
    var buildID: FXBuildID { get }
    var delegate: (any FXEngineDelegate)? { get }

    /// Create an ``InternalKey`` for the given key, capturing the typed
    /// engine in the function factory closure.
    func makeInternalKey<K: FXKey>(_ key: K, _ ctx: Context) -> InternalKey<K> where K.ValueType.DataID == DataID
}

// MARK: - FunctionInterface

internal final class FunctionInterface<DataID: FXDataIDProtocol>: Sendable {
    @usableFromInline
    let engine: any EngineInternalProtocol<DataID>

    let key: FXRequestKey

    init(engine: any EngineInternalProtocol<DataID>, key: FXRequestKey) {
        self.engine = engine
        self.key = key
    }

    func request<V: InternalResult>(_ key: FXRequestKey, as type: V.Type = V.self, _ ctx: Context) -> FXFuture<V> {
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

// MARK: - FXEngine

public typealias FXBuildID = Foundation.UUID

public final class FXEngine<DB: FXTypedCASDatabase>: Sendable {
    internal let group: FXFuturesDispatchGroup
    internal let db: DB
    @usableFromInline internal let cache: any FXFunctionCache<DB.DataID>
    internal let resources: [ResourceKey: FXResource]
    internal let executor: FXExecutor
    internal let treeService: (any FXTypedCASTreeService<DB.DataID>)?
    internal let stats: FXBuildEngineStats
    internal let logger: Logger?

    internal let keyOverrides: FXKeyOverrideRegistry?
    internal let cacheRequestOnly: Bool

    /// Delegate providing service-specific engine behavior (context preparation,
    /// telemetry hooks).
    public let delegate: (any FXEngineDelegate)?

    fileprivate let pendingResults: LLBEventualResultsCache<HashableKey, InternalResult>
    internal let keyDependencyGraph = FXKeyDependencyGraph()

    public let buildID: FXBuildID

    public init(
        group: FXFuturesDispatchGroup,
        db: DB,
        functionCache: (any FXFunctionCache<DB.DataID>)? = nil,
        executor: FXExecutor,
        treeService: (any FXTypedCASTreeService<DB.DataID>)? = nil,
        resources: [ResourceKey: FXResource] = [:],
        buildID: FXBuildID = FXBuildID(),
        stats: FXBuildEngineStats? = nil,
        logger: Logger? = nil,
        partialResultExpiration: DispatchTimeInterval = .seconds(300),
        keyOverrides: FXKeyOverrideRegistry? = nil,
        delegate: (any FXEngineDelegate)? = nil
    ) {
        self.group = group
        self.db = db
        self.cache = functionCache ?? FXInMemoryFunctionCache<DB.DataID>(group: group)
        self.resources = resources
        self.executor = executor
        self.treeService = treeService
        self.stats = stats ?? .init()
        self.logger = logger
        self.keyOverrides = keyOverrides
        self.delegate = delegate

        self.pendingResults = LLBEventualResultsCache<HashableKey, InternalResult>(group: group, partialResultExpiration: partialResultExpiration)

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

    /// Populate context with engine provided values.
    private func engineContext(_ ctx: Context) -> Context {
        var ctx = ctx
        ctx.group = self.group

        if let logger = self.logger {
            ctx.logger = logger
        }

        return ctx
    }
}

// MARK: - EngineInternalProtocol conformance

extension FXEngine: EngineInternalProtocol {
    typealias DataID = DB.DataID

    public func build<K: FXKey>(
        key: K,
        _ ctx: Context
    ) -> FXFuture<K.ValueType>
        where K.ValueType.DataID == DB.DataID
    {
        let ctx = engineContext(ctx)
        let ikey = key.internalKey(self, ctx)
        return self.build(key: ikey, as: InternalValue<K.ValueType>.self, ctx).map { internalValue in
            internalValue.value
        }
    }

    internal func build(key: FXRequestKey, _ ctx: Context) -> FXFuture<InternalResult> {
        let ctx = engineContext(ctx)
        return self.pendingResults.value(for: HashableKey(key: key)) { _ in
            guard let ikey = key as? any CallableKey<DB.DataID> else {
                return ctx.group.any().makeFailedFuture(FXError.nonCallableKey)
            }
            let fn = ikey.function()
            let fi = FunctionInterface<DB.DataID>(engine: self, key: key)
            return fn.compute(key: key, fi, ctx)
        }
    }

    internal func build<V: InternalResult>(key: FXRequestKey, as: V.Type, _ ctx: Context) -> FXFuture<V> {
        return self.build(key: key, ctx).flatMapThrowing {
            guard let value = $0 as? V else {
                throw FXError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }

    internal func cacheContains(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) -> FXFuture<Bool> {
        cache.get(key: key, props: props, ctx).map { $0 != nil }
    }

    internal func makeInternalKey<K: FXKey>(_ key: K, _ ctx: Context) -> InternalKey<K> where K.ValueType.DataID == DB.DataID {
        key.internalKey(self, ctx)
    }
}
