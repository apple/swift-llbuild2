// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIOConcurrencyHelpers
import NIOCore
import TSCUtility

// Explicitly re-export all of Futures/Utility/CAS/CASFileTree for easy of use
@_exported import TSFCASFileTree

public typealias Context = TSCUtility.Context

public protocol LLBKey: LLBStablyHashable {
    func hash(into hasher: inout Hasher)
    var hashValue: Int { get }

    /// Use for debugging purposes, should not be invoked by the engine unless the logger is configured for the trace
    /// level.
    func logDescription() -> String
}
public protocol LLBValue: LLBCASObjectRepresentable {}

public extension LLBKey {
    /// Default implementation for all keys. Keys can implement their own method if they want to display more relevant
    /// information.
    func logDescription() -> String {
        String(describing: type(of: self))
    }
}


public class LLBFunctionInterface {
    @usableFromInline
    let engine: LLBEngine

    let key: LLBKey

    /// The function execution cache
    @inlinable
    public var functionCache: LLBFunctionCache { return engine.functionCache }

    /// The serializable registry lookup interface
    @inlinable
    public var registry: LLBSerializableLookup { return engine.registry }

    init(engine: LLBEngine, key: LLBKey) {
        self.engine = engine
        self.key = key
    }

    public func request(_ key: LLBKey, _ ctx: Context) -> LLBFuture<LLBValue> {
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

    public func request<V: LLBValue>(_ key: LLBKey, as type: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
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

    public func spawn(_ action: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        return engine.executor.execute(request: action, ctx)
    }
}

public protocol LLBFunction {
    func compute(key: LLBKey, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<LLBValue>
}

public protocol LLBFunctionCache {
    func get(key: LLBKey, _ ctx: Context) -> LLBFuture<LLBDataID?>
    func update(key: LLBKey, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void>
}

open class LLBTypedCachingFunction<K: LLBKey, V: LLBValue>: LLBFunction {
    open var recomputeOnCacheFailure: Bool { false }

    public init() {}

    private func computeAndUpdate(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<LLBValue> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.computeAndUpdate(key: key, fi, ctx)
        }
    }

    private func computeAndUpdate(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) async throws -> LLBValue {
        defer { ctx.logger?.trace("    evaluated \(key.logDescription())") }

        let value = try await self.compute(key: key, fi, ctx).get()
        guard self.validateCache(key: key, cached: value) else {
            throw LLBError.inconsistentValue("\(String(describing: type(of: key))) evaluated to a value that does not pass its own validateCache() check!")
        }

        let resultID = try await ctx.db.put(try value.asCASObject(), ctx).get()
        _ = try await fi.functionCache.update(key: key, value: resultID, ctx).get()
        return value
    }

    private func unpack(_ object: LLBCASObject, _ fi: LLBFunctionInterface) throws -> V {
        if
            let type = V.self as? LLBPolymorphicSerializable.Type,
            let instance = try type.init(from: object, registry: fi.registry) as? V
        {
            return instance
        } else if
            let type = V.self as? LLBCASObjectConstructable.Type,
            let instance = try type.init(from: object) as? V
        {
            return instance
        } else {
            fatalError("cannot unpack CAS object")
        }
    }

    @_disfavoredOverload
    public func compute(key: LLBKey, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<LLBValue> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.compute(key: key, fi, ctx)
        }
    }

    @_disfavoredOverload
    public func compute(key: LLBKey, _ fi: LLBFunctionInterface, _ ctx: Context) async throws -> LLBValue {
        guard let typedKey = key as? K else {
            throw LLBError.unexpectedKeyType(String(describing: type(of: key)))
        }

        ctx.logger?.trace("evaluating \(key.logDescription())")

        guard let resultID = try await fi.functionCache.get(key: key, ctx).get(), let object = try await ctx.db.get(resultID, ctx).get() else {
            return try await self.computeAndUpdate(key: typedKey, fi, ctx).get()
        }

        do {
            let value: V = try self.unpack(object, fi)
            ctx.logger?.trace("    cached \(key.logDescription())")

            guard validateCache(key: typedKey, cached: value) else {
                guard let newValue = try await self.fixCached(key: typedKey, value: value, fi, ctx).get() else {
                    // Throw here to engage recomputeOnCacheFailure logic below.
                    throw LLBError.invalidValueType("failed to validate cache for \(String(describing: type(of: typedKey))), and fixCached() was not able to solve the problem")
                }

                let newResultID = try await ctx.db.put(try newValue.asCASObject(), ctx).get()
                _ = try await fi.functionCache.update(key: typedKey, value: newResultID, ctx).get()
                return newValue
            }

            return value
        } catch {
            guard self.recomputeOnCacheFailure else {
                throw error
            }

            return try await self.computeAndUpdate(key: typedKey, fi, ctx).get()
        }
    }

    open func compute(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<V> {
        // This is a developer error and not a runtime error, which is why fatalError is used.
        fatalError("unimplemented: this method is expected to be overridden by subclasses.")
    }

    open func validateCache(key: K, cached: V) -> Bool {
        return true
    }

    open func fixCached(key: K, value: V, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<V?> {
        return ctx.group.next().makeSucceededFuture(nil)
    }
}

public protocol LLBEngineDelegate {
    func registerTypes(registry: LLBSerializableRegistry)
    func lookupFunction(forKey: LLBKey, _ ctx: Context) -> LLBFuture<LLBFunction>
}

public extension LLBEngineDelegate {
    func registerTypes(registry: LLBSerializableRegistry) { }
}

public enum LLBError: Error {
    case invalidValueType(String)
    case unexpectedKeyType(String)
    case inconsistentValue(String)
}

internal struct Key {
    let key: LLBKey

    init(_ key: LLBKey) {
        self.key = key
    }
}
extension Key: Hashable {
    func hash(into hasher: inout Hasher) {
        key.hash(into: &hasher)
    }
    static func ==(lhs: Key, rhs: Key) -> Bool {
        return lhs.key.hashValue == rhs.key.hashValue
    }
}


public class LLBEngine {
    private let group: LLBFuturesDispatchGroup
    private let delegate: LLBEngineDelegate
    private let db: LLBCASDatabase
    fileprivate let executor: LLBExecutor
    fileprivate let pendingResults: LLBEventualResultsCache<Key, LLBValue>
    fileprivate let keyDependencyGraph = LLBKeyDependencyGraph()
    @usableFromInline internal let registry = LLBSerializableRegistry()
    @usableFromInline internal let functionCache: LLBFunctionCache


    public enum InternalError: Swift.Error {
        case noPendingTask
        case missingBuildResult
    }


    public init(
        group: LLBFuturesDispatchGroup = LLBMakeDefaultDispatchGroup(),
        delegate: LLBEngineDelegate,
        db: LLBCASDatabase? = nil,
        executor: LLBExecutor = LLBNullExecutor(),
        functionCache: LLBFunctionCache? = nil
    ) {
        self.group = group
        self.delegate = delegate
        self.db = db ?? LLBInMemoryCASDatabase(group: group)
        self.executor = executor
        self.pendingResults = LLBEventualResultsCache<Key, LLBValue>(group: group)
        self.functionCache = functionCache ?? LLBInMemoryFunctionCache(group: group)

        delegate.registerTypes(registry: registry)
    }

    /// Populate context with engine provided values
    private func engineContext(_ ctx: Context) -> Context {
        var ctx = ctx
        ctx.group = self.group
        ctx.db = self.db
        return ctx
    }

    public func build(key: LLBKey, _ ctx: Context) -> LLBFuture<LLBValue> {
        let ctx = engineContext(ctx)
        return self.pendingResults.value(for: Key(key)) { _ in
            return self.delegate.lookupFunction(forKey: key, ctx).flatMap { function in
                let fi = LLBFunctionInterface(engine: self, key: key)
                return function.compute(key: key, fi, ctx)
            }
        }
    }
}

extension LLBEngine {
    public func build<V: LLBValue>(key: LLBKey, as: V.Type, _ ctx: Context) -> LLBFuture<V> {
        return self.build(key: key, ctx).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }
}
