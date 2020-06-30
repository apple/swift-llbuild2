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

// Explicitly re-export all of Futures/Utility/CAS/CASFileTree for easy of use
@_exported import TSFCASFileTree

public typealias Context = TSCUtility.Context

public protocol LLBKey: LLBStablyHashable {
    func hash(into hasher: inout Hasher)
    var hashValue: Int { get }
}
public protocol LLBValue: LLBCASObjectRepresentable {}


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
        return engine.build(key: key, ctx)
    }

    public func request<V: LLBValue>(_ key: LLBKey, as type: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return ctx.group.next().makeFailedFuture(error)
        }
        return engine.build(key: key, as: type, ctx)
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
    public init() {}

    private func computeAndUpdate(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<LLBValue> {
        return self.compute(key: key, fi, ctx).flatMap { (value: LLBValue) in
            do {
                return ctx.db.put(try value.asCASObject(), ctx).flatMap { resultID in
                    return fi.functionCache.update(key: key, value: resultID, ctx).map {
                        return value
                    }
                }
            } catch {
                return ctx.group.next().makeFailedFuture(error)
            }
        }
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
        guard let typedKey = key as? K else {
            return ctx.group.next().makeFailedFuture(LLBError.unexpectedKeyType(String(describing: type(of: key))))
        }

        return fi.functionCache.get(key: key, ctx).flatMap { result -> LLBFuture<LLBValue> in
            if let resultID = result {
                return ctx.db.get(resultID, ctx).flatMap { objectOpt in
                    guard let object = objectOpt else {
                        return self.computeAndUpdate(key: typedKey, fi, ctx)
                    }
                    do {
                        let value: V = try self.unpack(object, fi)
                        return ctx.group.next().makeSucceededFuture(value)
                    } catch {
                        return ctx.group.next().makeFailedFuture(error)
                    }
                }
            }
            return self.computeAndUpdate(key: typedKey, fi, ctx)
        }
    }

    open func compute(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<V> {
        // This is a developer error and not a runtime error, which is why fatalError is used.
        fatalError("unimplemented: this method is expected to be overridden by subclasses.")
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
