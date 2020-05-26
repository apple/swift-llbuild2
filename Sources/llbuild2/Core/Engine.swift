// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import Crypto
import NIO
import NIOConcurrencyHelpers

public protocol LLBKey: Codable {}
public protocol LLBValue : Codable {}

extension LLBKey {
    public typealias KeyHash = Data

    public var stableHash: KeyHash {
        // Not super happy about this implementation, but this will get replaced anyways by the mechanism that will
        // translate between Keys and CAS IDs.

        // An important note here is that we need to encode the type as well, otherwise we might get 2 different keys
        // that contain the same fields and values, but actually represent different values.
        var hash = SHA256()

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let data = try! encoder.encode(["key": self])

        hash.update(data: data)

        var digest = [UInt8]()
        hash.finalize().withUnsafeBytes { pointer in
            digest.append(contentsOf: pointer)
        }
        return KeyHash(digest)
    }
}


public struct LLBResult {
    let changedAt: Int
    let value: LLBValue
    let dependencies: [LLBKey]
}

public class LLBFunctionInterface {
    let engine: LLBEngine

    public let group: EventLoopGroup

    init(group: EventLoopGroup, engine: LLBEngine) {
        self.engine = engine
        self.group = group
    }

    public func request(_ key: LLBKey) -> EventLoopFuture<LLBValue> {
        return engine.buildKey(key: key)
    }

    public func request<V: LLBValue>(_ key: LLBKey, as type: V.Type = V.self) -> EventLoopFuture<V> {
        return engine.buildKey(key: key, as: type)
    }

    // FIXME - implement these
    //    func spawn<T>(action: ()->T) -> EventLoopFuture<T>
    //    func spawn(args: [String], env: [String: String]) -> EventLoopFuture<ProcessResult...>
}

public protocol LLBFunction {
    func compute(key: LLBKey, _ fi: LLBFunctionInterface) -> EventLoopFuture<LLBValue>
}

public protocol LLBEngineDelegate {
    func lookupFunction(forKey: LLBKey, group: EventLoopGroup) -> EventLoopFuture<LLBFunction>
}

public enum LLBError: Error {
    case invalidValueType(String)
}

public class LLBEngine {
    public let group: EventLoopGroup

    fileprivate let lock = NIOConcurrencyHelpers.Lock()
    fileprivate let delegate: LLBEngineDelegate
    fileprivate var pendingResults: [LLBKey.KeyHash: EventLoopFuture<LLBValue>] = [:]


    public enum InternalError: Swift.Error {
        case noPendingTask
        case missingBuildResult
    }


    public init(
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        delegate: LLBEngineDelegate
    ) {
        self.group = group
        self.delegate = delegate
    }

    public func build(key: LLBKey, inputs: [LLBKey.KeyHash: LLBValue]? = nil) -> EventLoopFuture<LLBValue> {
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

    func buildKey(key: LLBKey) -> EventLoopFuture<LLBValue> {
        return lock.withLock {
            let keyID = key.stableHash
            if let value = pendingResults[keyID] {
                return value
            }

            // Create a promise to execute the body outside of the lock
            let promise = group.next().makePromise(of: LLBValue.self)
            group.next().flatSubmit {
                return self.delegate.lookupFunction(forKey: key, group: self.group).flatMap { function in
                    let fi = LLBFunctionInterface(group: self.group, engine: self)
                    return function.compute(key: key, fi)
                }
            }.cascade(to: promise)

            pendingResults[keyID] = promise.futureResult
            return promise.futureResult
        }
    }
}

extension LLBEngine {
    public func build<V: LLBValue>(key: LLBKey, inputs: [LLBKey.KeyHash: LLBValue]? = nil, as: V.Type) -> EventLoopFuture<V> {
        return self.build(key: key, inputs: inputs).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }

    func buildKey<V: LLBValue>(key: LLBKey, as: V.Type) -> EventLoopFuture<V> {
        return self.buildKey(key: key).flatMapThrowing {
            guard let value = $0 as? V else {
                throw LLBError.invalidValueType("Expected value of type \(V.self)")
            }
            return value
        }
    }
}
