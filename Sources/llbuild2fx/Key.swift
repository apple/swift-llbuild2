// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import TSCUtility

public protocol FXKey: Encodable, FXVersioning {
    associatedtype ValueType: FXValue

    static var volatile: Bool { get }

    static var recomputeOnCacheFailure: Bool { get }

    // A concise, human readable contents summary that may be used in otherwise
    // hashed contexts (i.e. when stored in caches, etc.)
    var hint: String? { get }

    /// Human-readable label for telemetry spans. Defaults to "KeyName/Version".
    var telemetryLabel: String { get }

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<ValueType>

    func validateCache(cached: ValueType) -> Bool
    func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<ValueType?>
}

extension FXKey {
    public static var volatile: Bool { false }

    public static var recomputeOnCacheFailure: Bool { true }

    public var hint: String? { nil }

    public var telemetryLabel: String { "\(Self.name)/\(Self.version)" }

    public func validateCache(cached: ValueType) -> Bool {
        return true
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<ValueType?> {
        return ctx.group.next().makeSucceededFuture(nil)
    }
}


extension FXKey {
    func internalKey<DB: FXTypedCASDatabase>(_ engine: FXEngine<DB>, _ ctx: Context) -> InternalKey<Self>
        where Self.ValueType.DataID == DB.DataID
    {
        InternalKey(self, engine: engine, ctx: ctx)
    }
}

private struct FXCacheKeyPrefixMemoizer {
    private static let lock = NIOLock()
    private static var prefixes: [ObjectIdentifier: String] = [:]

    static func get<K: FXVersioning>(for key: K) -> String {
        return lock.withLock {
            let objID = ObjectIdentifier(K.self)
            if let prefix = prefixes[objID] {
                return prefix
            }
            let prefix = K.cacheKeyPrefix
            prefixes[objID] = prefix
            return prefix
        }
    }

}

internal final class InternalKey<K: FXKey>: @unchecked Sendable {
    let name: String
    let key: K
    private let ctx: Context
    let stableHashValue: FXDataID
    let cachePath: String
    private let _function: @Sendable () -> any GenericFunction<K.ValueType.DataID>

    init<DB: FXTypedCASDatabase>(
        _ key: K, engine: FXEngine<DB>, ctx: Context
    ) where K.ValueType.DataID == DB.DataID {
        self.name = String(describing: K.self)
        self.key = key
        self.ctx = ctx
        let cachePath = Self.calculateCachePath(
            key: key,
            cacheRequestOnly: engine.cacheRequestOnly,
            buildID: engine.buildID,
            resources: engine.resources,
            ctx: ctx
        )
        let hashData = Array(cachePath.utf8)
        self.stableHashValue = FXDataID(blake3hash: hashData[...])
        self.cachePath = cachePath
        // Capture the typed engine in the function factory closure so
        // TypedFunction can access the native DB and cache.
        let db = engine.db
        let cache = engine.cache
        let treeService = engine.treeService
        self._function = { TypedFunction<K, DB>(db: db, cache: cache, treeService: treeService) }
    }

    /// Creates an InternalKey without proving the `DataID` constraint at
    /// compile time. The caller guarantees `K.ValueType.DataID == DB.DataID`
    /// holds at runtime. Used by ``FXEngine/buildUnchecked(key:_:)`` for
    /// existential key dispatch.
    init<DB: FXTypedCASDatabase>(
        unchecked key: K, engine: FXEngine<DB>, ctx: Context
    ) {
        self.name = String(describing: K.self)
        self.key = key
        self.ctx = ctx
        let cachePath = Self.calculateCachePath(
            key: key,
            cacheRequestOnly: engine.cacheRequestOnly,
            buildID: engine.buildID,
            resources: engine.resources,
            ctx: ctx
        )
        let hashData = Array(cachePath.utf8)
        self.stableHashValue = FXDataID(blake3hash: hashData[...])
        self.cachePath = cachePath
        let db = engine.db
        let cache = engine.cache
        let treeService = engine.treeService
        // TypedFunction<K, DB> requires K.ValueType.DataID == DB.DataID at the
        // type level. At runtime this is always true for keys dispatched through
        // buildUnchecked. We use _makeUncheckedFunction to bypass the constraint.
        self._function = { _makeUncheckedFunction(K.self, db: db, cache: cache, treeService: treeService) }
    }
}

extension InternalKey: FXKeyProperties {
    var volatile: Bool {
        K.volatile
    }

    static func calculateCachePath(
        key: K,
        cacheRequestOnly: Bool,
        buildID: FXBuildID,
        resources: [ResourceKey: FXResource],
        ctx: Context
    ) -> String {
        func cachePathWithoutConfig() -> String {
            let basePath = FXCacheKeyPrefixMemoizer.get(for: key)
            let keyLengthLimit = 250

            if key.hint == nil {
                // Without a hint, take a stab at a more friendly encoding
                let asArgs = try! CommandLineArgsEncoder().encode(key)
                let argsKey = asArgs.joined(separator: " ")

                guard argsKey.count > keyLengthLimit else {
                    return [basePath, argsKey].joined(separator: "/")
                }
            }

            let json = try! FXEncoder().encode(key)
            guard json.count > keyLengthLimit else {
                return [basePath, String(decoding: json, as: UTF8.self)].joined(separator: "/")
            }

            let hash = FXDataID(blake3hash: ArraySlice<UInt8>(json))
            let hashStr = ArraySlice(hash.bytes.dropFirst().prefix(9)).base64URL()
            let str: String
            if let hint = key.hint {
                str = "\(hint) \(hashStr)"
            } else {
                str = hashStr
            }
            return [basePath, str].joined(separator: "/")
        }

        let prefix: String
        if cacheRequestOnly {
            prefix = [buildID.uuidString, cachePathWithoutConfig()].joined(separator: "/")
        } else {
            prefix = cachePathWithoutConfig()
        }

        var path = [prefix]

        let config = KeyConfiguration<K>(inputs: ctx.fxConfigurationInputs)
        if !config.isNoop() {
            path.append(try! StringsEncoder().encode(config)[""]!)
        }

        let res = ResourceVersions<K>(resources: resources)
        if !res.isNoop() {
            path.append(try! StringsEncoder().encode(res)[""]!)
        }

        return path.joined(separator: "/")
    }
}

extension InternalKey: FXRequestKey {
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.stableHashValue)
    }

    var hashValue: Int {
        var hasher = Hasher()
        self.hash(into: &hasher)
        return hasher.finalize()
    }

    func logDescription() -> String {
        self.debugDescription
    }
}

extension InternalKey: CallableKey {
    typealias DataID = K.ValueType.DataID

    func function() -> any GenericFunction<K.ValueType.DataID> {
        _function()
    }
}

extension InternalKey: CustomDebugStringConvertible {
    var debugDescription: String {
        "KEY: //\(self.cachePath) [HASH: \(self.hashValue)]"
    }
}

private enum ParentUUIDKey {}
private enum SelfUUIDKey {}
private enum TraceIDKey {}

/// Support storing and retrieving a tracer instance from a Context.
extension Context {
    public var parentUUID: String? {
        get {
            guard let parentUUID = self[ObjectIdentifier(ParentUUIDKey.self), as: String.self] else {
                return nil
            }
            return parentUUID
        }
        set {
            self[ObjectIdentifier(ParentUUIDKey.self)] = newValue
        }
    }

    public var selfUUID: String? {
        get {
            guard let selfUUID = self[ObjectIdentifier(SelfUUIDKey.self), as: String.self] else {
                return nil
            }
            return selfUUID
        }
        set {
            self[ObjectIdentifier(SelfUUIDKey.self)] = newValue
        }
    }

    public var traceID: String? {
        get {
            guard let traceID = self[ObjectIdentifier(TraceIDKey.self), as: String.self] else {
                return nil
            }
            return traceID
        }
        set {
            self[ObjectIdentifier(TraceIDKey.self)] = newValue
        }
    }
}

/// Constructs a `GenericFunction` for key type `K` using database `DB`,
/// without requiring `K.ValueType.DataID == DB.DataID` at the call site.
/// The caller must guarantee the types match at runtime.
///
/// We can't construct TypedFunction<K, DB> directly (it carries the where
/// clause). Instead we construct TypedFunction<_AnyKey<DB.DataID>, DB> —
/// which satisfies the constraint trivially — and unsafeBitCast the result.
/// This is safe because TypedFunction's stored properties (db, cache,
/// treeService) only depend on DB, and its methods dispatch through the
/// key's FXKey conformance which is resolved at runtime.
private func _makeUncheckedFunction<K: FXKey, DB: FXTypedCASDatabase>(
    _ keyType: K.Type,
    db: DB,
    cache: any FXFunctionCache<DB.DataID>,
    treeService: (any FXTypedCASTreeService<DB.DataID>)?
) -> any GenericFunction<K.ValueType.DataID> {
    let fn: any GenericFunction<DB.DataID> = TypedFunction<_AnyKey<DB.DataID>, DB>(
        db: db, cache: cache, treeService: treeService
    )
    return unsafeBitCast(fn, to: (any GenericFunction<K.ValueType.DataID>).self)
}

/// Minimal FXKey stub whose ValueType.DataID matches a given DataID.
/// Used only by `_makeUncheckedFunction` to satisfy TypedFunction's
/// where clause at construction time.
private struct _AnyKey<DID: FXDataIDProtocol>: FXKey {
    struct Value: FXValue, Codable {
        typealias DataID = DID
        var refs: [DID] { [] }
        var codableValue: Value { self }
        init(refs: [DID], codableValue: Value) { self = codableValue }
    }
    typealias ValueType = Value
    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<Value> {
        fatalError("_AnyKey should never be evaluated")
    }
}

final class TypedFunction<K: FXKey, DB: FXTypedCASDatabase>: GenericFunction
    where K.ValueType.DataID == DB.DataID
{
    typealias DataID = DB.DataID
    let db: DB
    let cache: any FXFunctionCache<DB.DataID>
    let treeService: (any FXTypedCASTreeService<DB.DataID>)?

    init(db: DB, cache: any FXFunctionCache<DB.DataID>, treeService: (any FXTypedCASTreeService<DB.DataID>)?) {
        self.db = db
        self.cache = cache
        self.treeService = treeService
    }

    var recomputeOnCacheFailure: Bool { K.recomputeOnCacheFailure }

    enum Error: Swift.Error {
        case notCachePathProvider(FXRequestKey)
    }

    private func computeAndUpdate(key: InternalKey<K>, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) -> FXFuture<InternalResult> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.computeAndUpdate(key: key, fi, ctx)
        }
    }

    private func computeAndUpdate(key: InternalKey<K>, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) async throws -> InternalResult {
        defer { ctx.logger?.trace("    evaluated \(key.logDescription())") }

        let value = try await self.compute(key: key, fi, ctx).get()
        guard self.validateCache(key: key, cached: value) else {
            throw FXError.inconsistentValue("\(String(describing: type(of: key))) evaluated to a value that does not pass its own validateCache() check!")
        }

        let casObject: DB.CASObject = try value.asCASObject()
        let resultID = try await db.put(casObject, ctx).get()
        _ = try await cache.update(key: key, props: key, value: resultID, ctx).get()
        return value
    }

    private func unpack(_ object: DB.CASObject) throws -> InternalValue<K.ValueType> {
        return try InternalValue<K.ValueType>(from: object)
    }

    @_disfavoredOverload
    func compute(key: FXRequestKey, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) -> FXFuture<InternalResult> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.compute(key: key, fi, ctx)
        }
    }

    @_disfavoredOverload
    func compute(key untypedKey: FXRequestKey, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) async throws -> InternalResult {
        guard let key = untypedKey as? InternalKey<K> else {
            throw FXError.unexpectedKeyType(String(describing: type(of: untypedKey)))
        }

        ctx.logger?.trace("evaluating \(key.logDescription())")

        guard let resultID = try await cache.get(key: key, props: key, ctx).get(),
              let object: DB.CASObject = try await db.get(resultID, ctx).get()
        else {
            return try await self.computeAndUpdate(key: key, fi, ctx).get()
        }

        do {
            let value: InternalValue<K.ValueType> = try self.unpack(object)
            ctx.logger?.trace("    cached \(key.logDescription())")

            guard validateCache(key: key, cached: value) else {
                guard let newValue = try await self.fixCached(key: key, value: value, fi, ctx).get() else {
                    // Throw here to engage recomputeOnCacheFailure logic below.
                    throw FXError.invalidValueType("failed to validate cache for \(String(describing: type(of: key))), and fixCached() was not able to solve the problem")
                }

                let newCASObject: DB.CASObject = try newValue.asCASObject()
                let newResultID = try await db.put(newCASObject, ctx).get()
                _ = try await cache.update(key: key, props: key, value: newResultID, ctx).get()
                return newValue
            }

            return value
        } catch {
            guard self.recomputeOnCacheFailure else {
                throw error
            }

            return try await self.computeAndUpdate(key: key, fi, ctx).get()
        }
    }


    func compute(key: InternalKey<K>, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) -> FXFuture<
        InternalValue<K.ValueType>
    > {
        let actualKey = key.key

        // Check for test override before normal evaluation
        if let override = fi.engine.keyOverrides?.findOverride(for: K.self) {
            return ctx.group.any().makeFutureWithTask {
                let anyValue = try await override(actualKey)
                guard let value = anyValue as? K.ValueType else {
                    throw FXError.invalidValueType("Override for \(K.self) returned wrong type")
                }
                return InternalValue(value, requestedCacheKeyPaths: FXSortedSet<String>())
            }
        }

        let spawner = ConcreteActionSpawner(db: self.db, treeService: self.treeService, executor: fi.engine.executor, stats: fi.engine.stats)
        let fxfi = FXFunctionInterface(actualKey, fi, db: self.db, treeService: self.treeService, spawner: spawner, keyDescription: key.logDescription())

        let keyData = try! FXEncoder().encode(actualKey)
        let encodedKey = String(bytes: keyData, encoding: .utf8)!
        let keyPrefix = FXCacheKeyPrefixMemoizer.get(for: actualKey)
        let telemetryLabel = actualKey.telemetryLabel

        fi.engine.stats.add(key: key.name)

        var childContext = ctx

        childContext.parentUUID = ctx.selfUUID
        childContext.selfUUID = UUID().uuidString

        fi.engine.delegate?.prepareChildContext(&childContext)

        // Emit start event so traces show parent spans before children complete
        let startEvent = FXKeyEvaluationStartEvent(
            keyPrefix: keyPrefix,
            encodedKey: encodedKey,
            spanID: childContext.selfUUID ?? UUID().uuidString,
            parentSpanID: childContext.parentUUID,
            telemetryLabel: telemetryLabel
        )
        fi.engine.delegate?.keyEvaluationStarted(startEvent, childContext)

        let startTime = DispatchTime.now()

        return actualKey.computeValue(fxfi, childContext).flatMapError { underlyingError in
            let augmentedError: Swift.Error

            augmentedError = FXError.valueComputationError(
                keyPrefix: keyPrefix,
                key: encodedKey,
                error: underlyingError,
                requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot
            )

            return ctx.group.next().makeFailedFuture(augmentedError)
        }.map { value in
            return InternalValue(value, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot)
        }.always { result in
            fi.engine.stats.remove(key: key.name)

            let endTime = DispatchTime.now()
            let durationNs = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
            let durationMs = Int(durationNs / 1_000_000)

            let status: String
            switch result {
            case .success:
                status = "success"
            case .failure:
                status = "failure"
            }

            let event = FXKeyEvaluationEvent(
                keyPrefix: keyPrefix,
                encodedKey: encodedKey,
                spanID: childContext.selfUUID ?? UUID().uuidString,
                parentSpanID: childContext.parentUUID,
                durationMs: durationMs,
                status: status,
                startTime: Date(timeIntervalSinceNow: -Double(durationNs) / 1_000_000_000),
                telemetryLabel: telemetryLabel
            )
            fi.engine.delegate?.keyEvaluationCompleted(event, childContext)
        }
    }

    func validateCache(key: InternalKey<K>, cached: InternalValue<K.ValueType>) -> Bool {
        return key.key.validateCache(cached: cached.value)
    }

    func fixCached(key: InternalKey<K>, value: InternalValue<K.ValueType>, _ fi: FunctionInterface<DB.DataID>, _ ctx: Context) -> FXFuture<InternalValue<K.ValueType>?> {
        let actualKey = key.key

        let spawner = ConcreteActionSpawner(db: self.db, treeService: self.treeService, executor: fi.engine.executor, stats: fi.engine.stats)
        let fxfi = FXFunctionInterface(actualKey, fi, db: self.db, treeService: self.treeService, spawner: spawner, keyDescription: key.logDescription())
        return actualKey.fixCached(value: value.value, fxfi, ctx).map { maybeFixed in maybeFixed.map { InternalValue($0, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot) } }
    }
}

public protocol AsyncFXKey: FXKey {
    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType
    func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType?
}

extension AsyncFXKey {
    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<ValueType> {
        TaskCancellationRegistry.makeCancellableTask({
            try await self.computeValue(fi, ctx)
        }, ctx)
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<ValueType?> {
        ctx.group.any().makeFutureWithTask {
            try await fixCached(value: value, fi, ctx)
        }
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType? {
        return nil
    }
}
