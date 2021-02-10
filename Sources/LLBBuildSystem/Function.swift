// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

/// An "abstract" class that represents a build function, which includes a way to
/// statically specify the types of the build keys and values.
open class LLBBuildFunction<K: LLBBuildKey, V: LLBBuildValue>: LLBTypedCachingFunction<K, V> {
    override open func compute(key: K, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<V> {
        return evaluate(key: key, LLBBuildFunctionInterface(fi: fi), ctx).map { $0 }
    }

    /// Subclasses of LLBBuildFunction should override this method to provide the actual implementation of the function.
    open func evaluate(key: K, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<V> {
        fatalError("This needs to be implemented by subclasses.")
    }
}

/// A wrapper for the LLBFunctionInterface build system and static type support for build functions.
public final class LLBBuildFunctionInterface {
    private let fi: LLBFunctionInterface

    fileprivate init(fi: LLBFunctionInterface) {
        self.fi = fi
    }

    public var registry: LLBSerializableLookup {
        return fi.registry
    }

    /// Requests the value for a build key.
    func request<K: LLBBuildKey>(_ key: K, _ ctx: Context) -> LLBFuture<LLBBuildValue> {
        return self.fi.request(key, ctx).map { $0 as! LLBBuildValue }
    }

    /// Requests the value for a build key.
    public func request<K: LLBBuildKey, V: LLBBuildValue>(_ key: K, as valueType: V.Type = V.self, _ ctx: Context) -> LLBFuture<V> {
        return self.fi.request(key, ctx).map { $0 as! V }
    }

    /// Requests the values for a list of keys of the same type.
    func request<K: LLBBuildKey, V: LLBBuildValue>(_ keys: [K], as valueType: V.Type = V.self, _ ctx: Context) -> LLBFuture<[V]> {
        let requestFutures = keys.map { self.request($0, as: V.self, ctx) }
        return LLBFuture.whenAllSucceed(requestFutures, on: ctx.group.next())
    }

    internal func request(_ keys: [LLBBuildKey], _ ctx: Context) -> LLBFuture<[LLBBuildValue]> {
        let requestFutures = keys.map { self.fi.request($0, ctx).map { $0 as! LLBBuildValue} }
        return LLBFuture.whenAllSucceed(requestFutures, on: ctx.group.next())
    }

    func spawn(_ action: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        return fi.spawn(action, ctx)
    }
}

extension LLBBuildFunctionInterface {
    public func requestArtifact(_ artifact: LLBArtifact, _ ctx: Context) -> LLBFuture<LLBArtifactValue> {
        return self.request(artifact, as: LLBArtifactValue.self, ctx).map { $0 }
    }

    public func requestDependency(_ key: LLBConfiguredTargetKey, _ ctx: Context) -> LLBFuture<LLBProviderMap> {
        let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: key)
        return self.request(evaluatedTargetKey, as: LLBEvaluatedTargetValue.self, ctx).map { $0.providerMap }
    }

    public func requestDependencies(_ keys: [LLBConfiguredTargetKey], _ ctx: Context) -> LLBFuture<[LLBProviderMap]> {
        let evaluatedTargetKeys = keys.map { LLBEvaluatedTargetKey(configuredTargetKey: $0) }
        return self.request(evaluatedTargetKeys, as: LLBEvaluatedTargetValue.self, ctx).map { $0.map(\.providerMap) }
    }
}

extension LLBBuildFunctionInterface: LLBDynamicFunctionInterface {
    public func requestActionExecution(_ key: LLBActionExecutionKey, _ ctx: Context) -> LLBFuture<LLBActionExecutionValue> {
        return self.request(key, as: LLBActionExecutionValue.self, ctx)
    }
}

