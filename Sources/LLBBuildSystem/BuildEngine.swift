// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

public enum LLBBuildEngineError: Error {
    case unknownBuildKeyIdentifier(String)
    case unknownKeyType(String)
    case unexpectedValueType(String)
}

// Private delegate for implementing the LLBEngine delegate logic.
fileprivate class LLBBuildEngineDelegate: LLBEngineDelegate {
    private let engineContext: LLBBuildEngineContext
    private let functionMap: LLBBuildFunctionMap

    init(engineContext: LLBBuildEngineContext) {
        self.engineContext = engineContext
        self.functionMap = LLBBuildFunctionMap()
    }

    func lookupFunction(forKey key: LLBKey, group: LLBFuturesDispatchGroup) -> LLBFuture<LLBFunction> {
        if let buildKey = key as? LLBBuildKey {
            guard let function = functionMap.get(type(of: buildKey).identifier) else {
                return engineContext.group.next().makeFailedFuture(
                    LLBBuildEngineError.unknownBuildKeyIdentifier(String(describing: type(of: buildKey)))
                )
            }
            return engineContext.group.next().makeSucceededFuture(function)
        } else {
            return engineContext.group.next().makeFailedFuture(
                LLBBuildEngineError.unknownKeyType(String(describing: type(of: key)))
            )
        }
    }
}

/// LLBBuildEngine is the core piece for evaluating a build.
public final class LLBBuildEngine {
    private let coreEngine: LLBEngine
    private let delegate: LLBEngineDelegate
    private let engineContext: LLBBuildEngineContext

    public init(engineContext: LLBBuildEngineContext) {
        self.engineContext = engineContext
        self.delegate = LLBBuildEngineDelegate(engineContext: engineContext)
        self.coreEngine = LLBEngine(group: engineContext.group, delegate: delegate)
    }

    /// Requests the evaluation of a build key, returning an abstract build value.
    public func build(_ key: LLBBuildKey) -> LLBFuture<LLBBuildValue> {
        return self.coreEngine.build(key: key).flatMapThrowing { value -> LLBBuildValue in
            if let buildValue = value as? LLBBuildValue {
                return buildValue
            }
            throw LLBBuildEngineError.unexpectedValueType("expecting an LLBuildValue but got: \(String(describing: type(of: value)))")
        }
    }

    /// Requests the evaluation of a build key and attempts to cast the resulting value to the specified type.
    public func build<V: LLBBuildValue>(_ key: LLBBuildKey, as valueType: V.Type = V.self) -> LLBFuture<V> {
        return self.coreEngine.build(key: key).flatMapThrowing { value -> V in
            if let buildValue = value as? V {
                return buildValue
            }
            throw LLBBuildEngineError.unexpectedValueType("expecting \(String(describing: V.self)) but got: \(String(describing: type(of: value)))")
        }
    }
}
