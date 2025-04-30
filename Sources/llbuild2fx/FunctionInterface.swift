// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import NIOCore

public final class FXFunctionInterface<K: FXKey> {
    private let key: K
    private let fi: FunctionInterface
    private var requestedKeyCachePaths = FXSortedSet<String>()
    private let lock = NIOLock()
    var requestedCacheKeyPathsSnapshot: FXSortedSet<String> {
        lock.withLock {
            requestedKeyCachePaths
        }
    }

    init(_ key: K, _ fi: FunctionInterface) {
        self.key = key
        self.fi = fi
    }

    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) -> LLBFuture<X.ValueType> {
        do {
            let realX = x.internalKey(fi.engine, ctx)

            // Check that the key dependency is either explicity declared or
            // recursive/self-referential.
            guard K.versionDependencies.contains(where: { $0 == X.self }) || X.self == K.self else {
                throw FXError.unexpressedKeyDependency(
                    from: key.internalKey(fi.engine, ctx).logDescription(),
                    to: realX.logDescription()
                )
            }

            lock.withLock {
                _ = requestedKeyCachePaths.insert(realX.cachePath)
            }

            let cacheCheck: LLBFuture<Void>
            if requireCacheHit {
                cacheCheck = self.fi.functionCache.get(key: realX, props: realX, ctx).flatMapThrowing { maybeValue in
                    guard maybeValue != nil else {
                        throw FXError.missingRequiredCacheEntry(cachePath: realX.cachePath)
                    }

                    return
                }
            } else {
                cacheCheck = ctx.group.next().makeSucceededFuture(())
            }

            return cacheCheck.flatMap {
                self.fi.request(realX, as: InternalValue<X.ValueType>.self, ctx)
            }.map { internalValue in
                internalValue.value
            }
        } catch {
            return ctx.group.next().makeFailedFuture(error)
        }
    }

    public func spawn<ActionType: FXAction>(
        _ action: ActionType,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        guard K.actionDependencies.contains(where: { $0 == ActionType.self }) else {
            return ctx.group.any().makeFailedFuture(
                FXError.unexpressedKeyDependency(
                    from: key.internalKey(fi.engine, ctx).logDescription(),
                    to: "action: \(ActionType.name)"
                )
            )
        }

        fi.engine.stats.add(action: ActionType.name)

        ctx.logger?.debug("Will perform action: \(action)")
        let result = fi.engine.executor.perform(action, ctx)

        return result.always { _ in
            self.fi.engine.stats.remove(action: ActionType.name)
        }
    }


    @available(*, deprecated, message: "use spawn, with registered actions")
    public func execute<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>? = nil,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment {
        let actionName = String(describing: ActionType.self)

        fi.engine.stats.add(action: actionName)

        let executor = fi.engine.executor
        let result: LLBFuture<ActionType.ValueType>

        if executor.canSatisfy(requirements: requirements) {
            ctx.logger?.debug("Will perform action: \(action)")
            let exe = executable ?? ctx.group.next().makeFailedFuture(FXError.noExecutable)
            result = executor.perform(action: action, with: exe, requirements: requirements, ctx)
        } else {
            result = ctx.group.next().makeFailedFuture(FXError.executorCannotSatisfyRequirements)
        }

        return result.always { _ in
            self.fi.engine.stats.remove(action: actionName)
        }
    }

    @available(*, deprecated, message: "use spawn, with registered actions")
    public func execute<ActionType: FXAction>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>? = nil,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        execute(
            action: action,
            with: executable,
            requirements: ConstantPredicate(value: true),
            ctx
        )
    }

    public func resource<T>(_ key: ResourceKey) -> T? {
        if !K.resourceEntitlements.contains(key) {
            return nil
        }

        return fi.engine.resources[key] as? T
    }
}

extension FXFunctionInterface {
    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) async throws -> X.ValueType {
        return try await request(x, requireCacheHit: requireCacheHit, ctx).get()
    }

    public func spawn<ActionType: FXAction>(
        _ action: ActionType,
        _ ctx: Context
    ) async throws -> ActionType.ValueType {
        return try await spawn(action, ctx).get()
    }
}
