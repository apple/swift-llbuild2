// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import NIOCore

// MARK: - ActionSpawner (internal, hides DB)

internal protocol ActionSpawner<DataID>: Sendable {
    associatedtype DataID: FXDataIDProtocol
    func spawn<A: FXAction>(
        _ action: A,
        requirements: FXActionRequirements?,
        _ ctx: Context
    ) -> FXFuture<A.ValueType> where A.DataID == DataID
}

internal struct ConcreteActionSpawner<DB: FXTypedCASDatabase>: ActionSpawner {
    typealias DataID = DB.DataID
    let db: DB
    let treeService: (any FXTypedCASTreeService<DB.DataID>)?
    let executor: FXExecutor
    let stats: FXBuildEngineStats

    func spawn<A: FXAction>(
        _ action: A,
        requirements: FXActionRequirements?,
        _ ctx: Context
    ) -> FXFuture<A.ValueType> where A.DataID == DB.DataID {
        let ai = FXActionInterface(db: db, treeService: treeService)
        let result = executor.perform(action, ai: ai, requirements: requirements, ctx)
        return result.always { _ in
            self.stats.remove(action: A.name)
        }
    }
}

// MARK: - FXFunctionInterface

public final class FXFunctionInterface<K: FXKey>: Sendable {
    public let _db: any Sendable
    private let key: K
    private let fi: FunctionInterface<K.ValueType.DataID>
    private let treeService: (any FXTypedCASTreeService<K.ValueType.DataID>)?
    private let spawner: any ActionSpawner<K.ValueType.DataID>
    /// Pre-computed description of the owning key, used for error messages
    /// without requiring DataID constraints.
    private let keyDescription: String
    private let requestedKeyCachePaths = NIOLockedValueBox(FXSortedSet<String>())
    private let lock = NIOLock()
    var requestedCacheKeyPathsSnapshot: FXSortedSet<String> {
        return requestedKeyCachePaths.withLockedValue { return $0 }
    }

    init<DB: FXTypedCASDatabase>(
        _ key: K,
        _ fi: FunctionInterface<K.ValueType.DataID>,
        db: DB,
        treeService: (any FXTypedCASTreeService<K.ValueType.DataID>)?,
        spawner: any ActionSpawner<K.ValueType.DataID>,
        keyDescription: String
    ) where DB.DataID == K.ValueType.DataID {
        self.key = key
        self.fi = fi
        self._db = db
        self.treeService = treeService
        self.spawner = spawner
        self.keyDescription = keyDescription
    }

    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) -> FXFuture<X.ValueType>
        where X.ValueType.DataID == K.ValueType.DataID
    {
        do {
            let realX = fi.engine.makeInternalKey(x, ctx)

            // Check that the key dependency is either explicity declared or
            // recursive/self-referential.
            guard K.versionDependencies.contains(where: { $0 == X.self }) || X.self == K.self else {
                throw FXError.unexpressedKeyDependency(
                    from: keyDescription,
                    to: realX.logDescription()
                )
            }

            requestedKeyCachePaths.withLockedValue {
                $0.insert(realX.cachePath)
                return
            }

            let cacheCheck: FXFuture<Void>
            if requireCacheHit {
                cacheCheck = fi.engine.cacheContains(key: realX, props: realX, ctx).flatMapThrowing { exists in
                    guard exists else {
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
        requirements: FXActionRequirements? = nil,
        _ ctx: Context
    ) -> FXFuture<ActionType.ValueType>
        where ActionType.DataID == K.ValueType.DataID
    {
        guard K.actionDependencies.contains(where: { $0 == ActionType.self }) else {
            return ctx.group.any().makeFailedFuture(
                FXError.unexpressedKeyDependency(
                    from: keyDescription,
                    to: "action: \(ActionType.name)"
                )
            )
        }

        fi.engine.stats.add(action: ActionType.name)

        ctx.logger?.debug("Will perform action: \(action)")

        return spawner.spawn(action, requirements: requirements, ctx)
    }


    public func resource<T>(_ key: ResourceKey) -> T? {
        if !K.resourceEntitlements.contains(key) {
            return nil
        }

        return fi.engine.resources[key] as? T
    }
}

extension FXFunctionInterface where K.ValueType.DataID == FXDataID {
    public var db: any FXCASDatabase { self._db as! any FXCASDatabase }
}

extension FXFunctionInterface {
    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) async throws -> X.ValueType
        where X.ValueType.DataID == K.ValueType.DataID
    {
        return try await request(x, requireCacheHit: requireCacheHit, ctx).get()
    }

    public func spawn<ActionType: FXAction>(
        _ action: ActionType,
        requirements: FXActionRequirements? = nil,
        _ ctx: Context
    ) async throws -> ActionType.ValueType
        where ActionType.DataID == K.ValueType.DataID
    {
        return try await spawn(action, requirements: requirements, ctx).get()
    }
}
