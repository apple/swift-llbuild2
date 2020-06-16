// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import Crypto
import NIOConcurrencyHelpers

@_exported import LLBCAS
@_exported import LLBCASFileTree
@_exported import LLBSupport


public protocol LLBKey {
    func hash(into: inout Hasher)
    var hashValue: Int { get }
}
public protocol LLBValue: LLBSerializable {}

public struct LLBResult {
    let changedAt: Int
    let value: LLBValue
    let dependencies: [LLBKey]
}

public class LLBFunctionInterface {
    @usableFromInline
    let engine: LLBEngine

    let key: LLBKey

    /// The dispatch group to be used as when processing the future blocks throughout the build.
    @inlinable
    public var group: LLBFuturesDispatchGroup { return engine.group }

    /// The CAS database reference to use for interfacing with CAS systems.
    @inlinable
    public var db: LLBCASDatabase { return engine.db }

    init(engine: LLBEngine, key: LLBKey) {
        self.engine = engine
        self.key = key
    }

    public func request(_ key: LLBKey) -> LLBFuture<LLBValue> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return group.next().makeFailedFuture(error)
        }
        return engine.build(key: key)
    }

    public func request<V: LLBValue>(_ key: LLBKey, as type: V.Type = V.self) -> LLBFuture<V> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return group.next().makeFailedFuture(error)
        }
        return engine.build(key: key, as: type)
    }

    public func spawn(_ action: LLBActionExecutionRequest, _ ctx: LLBBuildEngineContext) -> LLBFuture<LLBActionExecutionResponse> {
        return engine.executor.execute(request: action, ctx)
    }
}

public protocol LLBFunction {
    func compute(key: LLBKey, _ fi: LLBFunctionInterface) -> LLBFuture<LLBValue>
}

public protocol LLBEngineDelegate {
    func lookupFunction(forKey: LLBKey, group: LLBFuturesDispatchGroup) -> LLBFuture<LLBFunction>
}

public enum LLBError: Error {
    case invalidValueType(String)
}

fileprivate struct Key {
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
    public let group: LLBFuturesDispatchGroup

    fileprivate let lock = NIOConcurrencyHelpers.Lock()
    fileprivate let delegate: LLBEngineDelegate
    @usableFromInline internal let db: LLBCASDatabase
    fileprivate let executor: LLBExecutor
    fileprivate let pendingResults: LLBEventualResultsCache<Key, LLBValue>
    fileprivate let keyDependencyGraph = LLBKeyDependencyGraph()


    public enum InternalError: Swift.Error {
        case noPendingTask
        case missingBuildResult
    }


    public init(
        group: LLBFuturesDispatchGroup = LLBMakeDefaultDispatchGroup(),
        delegate: LLBEngineDelegate,
        db: LLBCASDatabase? = nil,
        executor: LLBExecutor = LLBNullExecutor()
    ) {
        self.group = group
        self.delegate = delegate
        self.db = db ?? LLBInMemoryCASDatabase(group: group)
        self.executor = executor
        self.pendingResults = LLBEventualResultsCache<Key, LLBValue>(group: group)
    }

    public func build(key: LLBKey) -> LLBFuture<LLBValue> {
        return self.pendingResults.value(for: Key(key)) { _ in
            return self.delegate.lookupFunction(forKey: key, group: self.group).flatMap { function in
                let fi = LLBFunctionInterface(engine: self, key: key)
                return function.compute(key: key, fi)
            }
        }
    }
}

extension LLBEngine {
    public func build<V: LLBValue>(key: LLBKey, as: V.Type) -> LLBFuture<V> {
        return self.build(key: key).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }
}
