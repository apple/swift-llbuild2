// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import LLBUtil
import NIO

public func LLBMakeTestContext() -> Context {
    var ctx = Context()
    ctx.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    ctx.db = LLBTestCASDatabase(group: ctx.group)
    return ctx
}

/// Test implementation of a build engine to be used for inspection during tests. This class is a wrapper around an
/// actual LLBBuildEngine.
public class LLBTestBuildEngine {
    private let engine: LLBBuildEngine

    private struct RegistrationDelegateWrapper: LLBSerializableRegistrationDelegate {
        let handler: (LLBSerializableRegistry) -> Void

        public func registerTypes(registry: LLBSerializableRegistry) {
            handler(registry)
        }
    }

    public init(
        group: LLBFuturesDispatchGroup,
        db: LLBCASDatabase,
        buildFunctionLookupDelegate: LLBBuildFunctionLookupDelegate? = nil,
        configuredTargetDelegate: LLBConfiguredTargetDelegate? = nil,
        ruleLookupDelegate: LLBRuleLookupDelegate? = nil,
        dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate? = nil,
        executor: LLBExecutor? = nil,
        registrationHandler: @escaping (LLBSerializableRegistry) -> Void = { _ in }
    ) {

        self.engine = LLBBuildEngine(
            group: group,
            db: db,
            buildFunctionLookupDelegate: buildFunctionLookupDelegate,
            configuredTargetDelegate: configuredTargetDelegate,
            ruleLookupDelegate: ruleLookupDelegate,
            registrationDelegate: RegistrationDelegateWrapper(handler: registrationHandler),
            dynamicActionExecutorDelegate: dynamicActionExecutorDelegate,
            executor: executor ?? LLBNullExecutor()
        )
    }

    /// Requests the evaluation of a build key, returning an abstract build value.
    public func build(_ key: LLBBuildKey, _ ctx: Context) -> LLBFuture<LLBBuildValue> {
        return self.engine.build(key, ctx)
    }

    /// Requests the evaluation of a build key and attempts to cast the resulting value to the specified type.
    public func build<V: LLBBuildValue>(_ key: LLBBuildKey, as valueType: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
        return self.engine.build(key, ctx)
    }
}
