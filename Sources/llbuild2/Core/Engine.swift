// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


import Crypto
import NIOConcurrencyHelpers

@_exported import LLBCAS
@_exported import LLBCASFileTree
@_exported import LLBSupport


public protocol LLBKey: LLBSerializable {}
public protocol LLBValue: LLBSerializable {}

extension LLBKey {
    public typealias Digest = [UInt8]

    public var digest: Digest {
        var hash = SHA256()

        var data = try! self.toBytes()

        // An important note here is that we need to encode the type as well, otherwise we might get 2 different keys
        // that contain the same fields and values, but actually represent different values.
        hash.update(data: String(describing: type(of: self)).data(using: .utf8)!)
        hash.update(data: data.readBytes(length: data.readableBytes)!)

        var digest = [UInt8]()
        hash.finalize().withUnsafeBytes { pointer in
            digest.append(contentsOf: pointer)
        }

        return digest
    }
}

public struct LLBResult {
    let changedAt: Int
    let value: LLBValue
    let dependencies: [LLBKey]
}

public class LLBFunctionInterface {
    let engine: LLBEngine
    let key: LLBKey

    public let group: LLBFuturesDispatchGroup

    init(group: LLBFuturesDispatchGroup, engine: LLBEngine, key: LLBKey) {
        self.engine = engine
        self.group = group
        self.key = key
    }

    public func request(_ key: LLBKey) -> LLBFuture<LLBValue> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return group.next().makeFailedFuture(error)
        }
        return engine.buildKey(key: key)
    }

    public func request<V: LLBValue>(_ key: LLBKey, as type: V.Type = V.self) -> LLBFuture<V> {
        do {
            try engine.keyDependencyGraph.addEdge(from: self.key, to: key)
        } catch {
            return group.next().makeFailedFuture(error)
        }
        return engine.buildKey(key: key, as: type)
    }

    // FIXME - implement these
    //    func spawn<T>(action: ()->T) -> LLBFuture<T>
    //    func spawn(args: [String], env: [String: String]) -> LLBFuture<ProcessResult...>
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

public class LLBEngine {
    public let group: LLBFuturesDispatchGroup

    fileprivate let lock = NIOConcurrencyHelpers.Lock()
    fileprivate let delegate: LLBEngineDelegate
    fileprivate var pendingResults: [LLBKey.Digest: LLBFuture<LLBValue>] = [:]
    fileprivate let keyDependencyGraph = LLBKeyDependencyGraph()


    public enum InternalError: Swift.Error {
        case noPendingTask
        case missingBuildResult
    }


    public init(
        group: LLBFuturesDispatchGroup = LLBMakeDefaultDispatchGroup(),
        delegate: LLBEngineDelegate
    ) {
        self.group = group
        self.delegate = delegate
    }

    public func build(key: LLBKey, inputs: [LLBKey.Digest: LLBValue]? = nil) -> LLBFuture<LLBValue> {
        // Set static input results if needed
        if let inputs = inputs {
            lock.withLockVoid {
                for (k, v) in inputs {
                    self.pendingResults[k] = self.group.next().makeSucceededFuture(v)
                }
            }
        }

        // Build the key
        return buildKey(key: key)
    }

    func buildKey(key: LLBKey) -> LLBFuture<LLBValue> {
        return lock.withLock {
            let keyID = key.digest
            if let value = pendingResults[keyID] {
                return value
            }

            // Create a promise to execute the body outside of the lock
            let promise = group.next().makePromise(of: LLBValue.self)
            group.next().flatSubmit {
                return self.delegate.lookupFunction(forKey: key, group: self.group).flatMap { function in
                    let fi = LLBFunctionInterface(group: self.group, engine: self, key: key)
                    return function.compute(key: key, fi)
                }
            }.cascade(to: promise)

            pendingResults[keyID] = promise.futureResult
            return promise.futureResult
        }
    }
}

extension LLBEngine {
    public func build<V: LLBValue>(key: LLBKey, inputs: [LLBKey.Digest: LLBValue]? = nil, as: V.Type) -> LLBFuture<V> {
        return self.build(key: key, inputs: inputs).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }

    func buildKey<V: LLBValue>(key: LLBKey, as: V.Type) -> LLBFuture<V> {
        return self.buildKey(key: key).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }
}
