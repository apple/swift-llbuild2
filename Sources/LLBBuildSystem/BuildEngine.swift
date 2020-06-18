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

extension LLBBuildEngineError: Equatable {}

public protocol LLBSerializableRegistrationDelegate {
    func registerTypes(registry: LLBSerializableRegistry)
}


// Private delegate for implementing the LLBEngine delegate logic.
fileprivate class LLBBuildEngineDelegate: LLBEngineDelegate {
    private let engineContext: LLBBuildEngineContext
    private let functionMap: LLBBuildFunctionMap
    private let buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate?
    private let registrationDelegate: LLBSerializableRegistrationDelegate?

    init(
        engineContext: LLBBuildEngineContext,
        buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate?,
        configuredTargetDelegate: LLBConfiguredTargetDelegate?,
        ruleLookupDelegate: LLBRuleLookupDelegate?,
        registrationDelegate: LLBSerializableRegistrationDelegate?
    ) {
        self.engineContext = engineContext
        self.buildFunctionLookupDelegate = buildFunctionLookupDelegate
        self.registrationDelegate = registrationDelegate
        self.functionMap = LLBBuildFunctionMap(
            engineContext: engineContext,
            configuredTargetDelegate: configuredTargetDelegate,
            ruleLookupDelegate: ruleLookupDelegate
        )
    }

    func lookupFunction(forKey key: LLBKey, group: LLBFuturesDispatchGroup) -> LLBFuture<LLBFunction> {
        if let buildKey = key as? LLBBuildKey {
            // First look in the build system function map, and if not found, resolve it using the delegate.
            guard let function = functionMap.get(type(of: buildKey).identifier) ??
                    buildFunctionLookupDelegate?.lookupBuildFunction(for: type(of: buildKey).identifier) else {
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

    func registerTypes(registry: LLBSerializableRegistry) {
        registrationDelegate?.registerTypes(registry: registry)
    }
}

/// LLBBuildEngine is the core piece for evaluating a build.
public final class LLBBuildEngine {
    private let coreEngine: LLBEngine
    private let delegate: LLBEngineDelegate
    private let engineContext: LLBBuildEngineContext

    /// Builds a new instance of an LLBBuildEngine.
    ///
    /// - Parameters:
    ///     - engineContext: The context for the engine.
    ///     - buildFunctionLookupDelegate: An optional delegate for resolving build functions at runtime. The build
    ///           engine will first look in the internal function map, and only resolve using the delegate if it can't
    ///           find a function to use for a particular key.
    ///     - configuredTargetDelegate: An optional delegate used for finding a configured target from the workspace. If
    ///           not specified, will trigger an error when a ConfiguredTargetKey is requested.
    ///     - ruleLookupDelegate: An optional rule lookup delegate used for retrieving the rule implementation to
    ///           evaluate a configured target. If not specified, will trigger an error if an EvaluatedTargetKey is
    ///           requested.
    public init(
        engineContext: LLBBuildEngineContext,
        buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate? = nil,
        configuredTargetDelegate: LLBConfiguredTargetDelegate? = nil,
        ruleLookupDelegate: LLBRuleLookupDelegate? = nil,
        registrationDelegate: LLBSerializableRegistrationDelegate? = nil,
        db: LLBCASDatabase,
        executor: LLBExecutor
    ) {
        self.engineContext = engineContext
        self.delegate = LLBBuildEngineDelegate(
            engineContext: engineContext,
            buildFunctionLookupDelegate: buildFunctionLookupDelegate,
            configuredTargetDelegate: configuredTargetDelegate,
            ruleLookupDelegate: ruleLookupDelegate,
            registrationDelegate: registrationDelegate
        )
        self.coreEngine = LLBEngine(group: engineContext.group, delegate: delegate, db: db, executor: executor)
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
