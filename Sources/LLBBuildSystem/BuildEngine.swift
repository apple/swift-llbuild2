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
    private let functionMap: LLBBuildFunctionMap
    private let buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate?
    private let registrationDelegate: LLBSerializableRegistrationDelegate?

    init(
        buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate?,
        configuredTargetDelegate: LLBConfiguredTargetDelegate?,
        ruleLookupDelegate: LLBRuleLookupDelegate?,
        registrationDelegate: LLBSerializableRegistrationDelegate?,
        dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?
    ) {
        self.buildFunctionLookupDelegate = buildFunctionLookupDelegate
        self.registrationDelegate = registrationDelegate
        self.functionMap = LLBBuildFunctionMap(
            configuredTargetDelegate: configuredTargetDelegate,
            ruleLookupDelegate: ruleLookupDelegate,
            dynamicActionExecutorDelegate: dynamicActionExecutorDelegate
        )
    }

    func lookupFunction(forKey key: LLBKey, _ ctx: Context) -> LLBFuture<LLBFunction> {
        if let buildKey = key as? LLBBuildKey {
            // First look in the build system function map, and if not found, resolve it using the delegate.
            guard let function = functionMap.get(type(of: buildKey).identifier) ??
                    buildFunctionLookupDelegate?.lookupBuildFunction(for: type(of: buildKey).identifier) else {
                return ctx.group.next().makeFailedFuture(
                    LLBBuildEngineError.unknownBuildKeyIdentifier(String(describing: type(of: buildKey)))
                )
            }
            return ctx.group.next().makeSucceededFuture(function)
        } else {
            return ctx.group.next().makeFailedFuture(
                LLBBuildEngineError.unknownKeyType(String(describing: type(of: key)))
            )
        }
    }

    func registerTypes(registry: LLBSerializableRegistry) {
        registry.register(type: LLBActionConfigurationFragmentKey.self)
        registry.register(type: LLBActionConfigurationFragment.self)
        registrationDelegate?.registerTypes(registry: registry)
    }
}

/// LLBBuildEngine is the core piece for evaluating a build.
public final class LLBBuildEngine {
    private let coreEngine: LLBEngine
    private let delegate: LLBEngineDelegate

    /// Builds a new instance of an LLBBuildEngine.
    ///
    /// - Parameters:
    ///     - buildFunctionLookupDelegate: An optional delegate for resolving build functions at runtime. The build
    ///           engine will first look in the internal function map, and only resolve using the delegate if it can't
    ///           find a function to use for a particular key.
    ///     - configuredTargetDelegate: An optional delegate used for finding a configured target from the workspace. If
    ///           not specified, will trigger an error when a ConfiguredTargetKey is requested.
    ///     - ruleLookupDelegate: An optional rule lookup delegate used for retrieving the rule implementation to
    ///           evaluate a configured target. If not specified, will trigger an error if an EvaluatedTargetKey is
    ///           requested.
    ///     - registrationDelegate: An optional delegate providing a hook for registering types that need to be
    ///           pre-declared for polymorphic serialization.
    ///     - dynamicActionExecutorDelegate: An optional delegate that is required if the build system implements
    ///           support for dynamic actions. The purpose of this delegate is to find the dynamic action implementation
    ///           from the identifier encoded in the action key.
    ///     - executor: The executor that will execute the actions.
    ///     - functionCache: The function cache that acts as the memoization layer for the core llbuild2 engine.
    public init(
        group: LLBFuturesDispatchGroup,
        db: LLBCASDatabase,
        buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate? = nil,
        configuredTargetDelegate: LLBConfiguredTargetDelegate? = nil,
        ruleLookupDelegate: LLBRuleLookupDelegate? = nil,
        registrationDelegate: LLBSerializableRegistrationDelegate? = nil,
        dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate? = nil,
        executor: LLBExecutor,
        functionCache: LLBFunctionCache? = nil
    ) {
        self.delegate = LLBBuildEngineDelegate(
            buildFunctionLookupDelegate: buildFunctionLookupDelegate,
            configuredTargetDelegate: configuredTargetDelegate,
            ruleLookupDelegate: ruleLookupDelegate,
            registrationDelegate: registrationDelegate,
            dynamicActionExecutorDelegate: dynamicActionExecutorDelegate
        )
        self.coreEngine = LLBEngine(
            group: group,
            delegate: delegate,
            db: db,
            executor: executor,
            functionCache: functionCache
        )
    }

    /// Requests the evaluation of a build key, returning an abstract build value.
    public func build(_ key: LLBBuildKey, _ ctx: Context) -> LLBFuture<LLBBuildValue> {
        return self.coreEngine.build(key: key, ctx).flatMapThrowing { value -> LLBBuildValue in
            if let buildValue = value as? LLBBuildValue {
                return buildValue
            }
            throw LLBBuildEngineError.unexpectedValueType("expecting an LLBuildValue but got: \(String(describing: type(of: value)))")
        }
    }

    /// Requests the evaluation of a build key and attempts to cast the resulting value to the specified type.
    public func build<V: LLBBuildValue>(_ key: LLBBuildKey, as valueType: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
        return self.coreEngine.build(key: key, ctx).flatMapThrowing { value -> V in
            if let buildValue = value as? V {
                return buildValue
            }
            throw LLBBuildEngineError.unexpectedValueType("expecting \(String(describing: V.self)) but got: \(String(describing: type(of: value)))")
        }
    }
}
