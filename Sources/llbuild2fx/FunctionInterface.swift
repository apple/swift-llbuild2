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
            let realX = x.internalKey(ctx)

            // Check that the key dependency is either explicity declared or
            // recursive/self-referential.
            guard K.versionDependencies.contains(where: { $0 == X.self }) || X.self == K.self else {
                throw FXError.unexpressedKeyDependency(
                    from: key.internalKey(ctx).logDescription(),
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

    public func execute<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>? = nil,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment {
        let actionName = String(describing: ActionType.self)

        ctx.fxBuildEngineStats.add(action: actionName)

        let executor = ctx.fxExecutor!
        let result: LLBFuture<ActionType.ValueType>

        if executor.canSatisfy(requirements: requirements) {
            ctx.logger?.debug("Will perform action: \(action)")
            let exe = executable ?? ctx.group.next().makeFailedFuture(FXError.noExecutable)
            result = executor.perform(action: action, with: exe, requirements: requirements, ctx)
        } else {
            result = ctx.group.next().makeFailedFuture(FXError.executorCannotSatisfyRequirements)
        }

        return result.always { _ in
            ctx.fxBuildEngineStats.remove(action: actionName)
        }
    }

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
}
