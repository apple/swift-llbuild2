// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import TSCUtility
import Tracing
import Logging

public protocol FXKey: Encodable, FXVersioning {
    associatedtype ValueType: FXValue

    static var volatile: Bool { get }

    static var recomputeOnCacheFailure: Bool { get }

    // A concise, human readable contents summary that may be used in otherwise
    // hashed contexts (i.e. when stored in caches, etc.)
    var hint: String? { get }

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType>

    func validateCache(cached: ValueType) -> Bool
    func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType?>
}

extension FXKey {
    public static var volatile: Bool { false }

    public static var recomputeOnCacheFailure: Bool { true }

    public var hint: String? { nil }

    public func validateCache(cached: ValueType) -> Bool {
        return true
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType?> {
        return ctx.group.next().makeSucceededFuture(nil)
    }
}


internal extension FXKey {
    func internalKey(_ engine: FXEngine, _ ctx: Context) -> InternalKey<Self> {
        InternalKey(self, engine, ctx)
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

internal final class InternalKey<K: FXKey> {
    let name: String
    let key: K
    private let ctx: Context
    let stableHashValue: LLBDataID
    let cachePath: String

    init(_ key: K, _ engine: FXEngine, _ ctx: Context) {
        self.name = String(describing: K.self)
        self.key = key
        self.ctx = ctx
        let cachePath = Self.calculateCachePath(key: key, engine: engine, ctx: ctx)
        let hashData = Array(cachePath.utf8)
        self.stableHashValue = LLBDataID(blake3hash: hashData[...])
        self.cachePath = cachePath
    }
}

extension InternalKey: FXKeyProperties {
    var volatile: Bool {
        K.volatile
    }

    static func calculateCachePath(key: K, engine: FXEngine, ctx: Context) -> String {
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

            let hash = LLBDataID(blake3hash: ArraySlice<UInt8>(json))
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
        if engine.cacheRequestOnly {
            prefix = [engine.buildID.uuidString, cachePathWithoutConfig()].joined(separator: "/")
        } else {
            prefix = cachePathWithoutConfig()
        }

        var path = [prefix]

        let config = KeyConfiguration<K>(inputs: ctx.fxConfigurationInputs)
        if !config.isNoop() {
            path.append(try! StringsEncoder().encode(config)[""]!)
        }

        let res = ResourceVersions<K>(resources: engine.resources)
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
    func function() -> GenericFunction {
        TypedFunction<K>()
    }
}

extension InternalKey: CustomDebugStringConvertible {
    var debugDescription: String {
        "KEY: //\(self.cachePath) [HASH: \(self.hashValue)]"
    }
}

private enum ParentUUIDKey { }
private enum SelfUUIDKey { }
private enum TraceIDKey { }

/// Support storing and retrieving a tracer instance from a Context.
public extension Context {
    var parentUUID: String? {
        get {
            guard let parentUUID = self[ObjectIdentifier(ParentUUIDKey.self)] as? String else {
                return nil
            }
            return parentUUID
        }
        set {
            self[ObjectIdentifier(ParentUUIDKey.self)] = newValue
        }
    }

    var selfUUID: String? {
        get {
            guard let selfUUID = self[ObjectIdentifier(SelfUUIDKey.self)] as? String else {
                return nil
            }
            return selfUUID
        }
        set {
            self[ObjectIdentifier(SelfUUIDKey.self)] = newValue
        }
    }

    var traceID: String? {
        get {
            guard let traceID = self[ObjectIdentifier(TraceIDKey.self)] as? String else {
                return nil
            }
            return traceID
        }
        set {
            self[ObjectIdentifier(TraceIDKey.self)] = newValue
        }
    }
}

final class TypedFunction<K: FXKey>: GenericFunction {
    var recomputeOnCacheFailure: Bool { K.recomputeOnCacheFailure }

    enum Error: Swift.Error {
        case notCachePathProvider(FXRequestKey)
    }

    private func computeAndUpdate(key: InternalKey<K>, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<FXResult> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.computeAndUpdate(key: key, fi, ctx)
        }
    }

    private func computeAndUpdate(key: InternalKey<K>, _ fi: FunctionInterface, _ ctx: Context) async throws -> FXResult {
        defer { ctx.logger?.trace("    evaluated \(key.logDescription())") }

        let value = try await self.compute(key: key, fi, ctx).get()
        guard self.validateCache(key: key, cached: value) else {
            throw FXError.inconsistentValue("\(String(describing: type(of: key))) evaluated to a value that does not pass its own validateCache() check!")
        }

        let resultID = try await ctx.db.put(try value.asCASObject(), ctx).get()
        _ = try await fi.functionCache.update(key: key, props: key, value: resultID, ctx).get()
        return value
    }

    private func unpack(_ object: LLBCASObject, _ fi: FunctionInterface) throws -> InternalValue<K.ValueType> {
        return try InternalValue<K.ValueType>.init(from: object)
    }

    @_disfavoredOverload
    func compute(key: FXRequestKey, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<FXResult> {
        return ctx.group.any().makeFutureWithTask {
            return try await self.compute(key: key, fi, ctx)
        }
    }

    @_disfavoredOverload
    func compute(key untypedKey: FXRequestKey, _ fi: FunctionInterface, _ ctx: Context) async throws -> FXResult {
        guard let key = untypedKey as? InternalKey<K> else {
            throw FXError.unexpectedKeyType(String(describing: type(of: untypedKey)))
        }

        ctx.logger?.trace("evaluating \(key.logDescription())")

        guard let resultID = try await fi.functionCache.get(key: key, props: key, ctx).get(), let object = try await ctx.db.get(resultID, ctx).get() else {
            return try await self.computeAndUpdate(key: key, fi, ctx).get()
        }

        do {
            let value: InternalValue<K.ValueType> = try self.unpack(object, fi)
            ctx.logger?.trace("    cached \(key.logDescription())")

            guard validateCache(key: key, cached: value) else {
                guard let newValue = try await self.fixCached(key: key, value: value, fi, ctx).get() else {
                    // Throw here to engage recomputeOnCacheFailure logic below.
                    throw FXError.invalidValueType("failed to validate cache for \(String(describing: type(of: key))), and fixCached() was not able to solve the problem")
                }

                let newResultID = try await ctx.db.put(try newValue.asCASObject(), ctx).get()
                _ = try await fi.functionCache.update(key: key, props: key, value: newResultID, ctx).get()
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


    func compute(key: InternalKey<K>, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<
        InternalValue<K.ValueType>
    > {
        let actualKey = key.key

        let fxfi = FXFunctionInterface(actualKey, fi)

        let keyData = try! FXEncoder().encode(actualKey)
        let encodedKey = String(bytes: keyData, encoding: .utf8)!
        let keyPrefix = FXCacheKeyPrefixMemoizer.get(for: actualKey)

        fi.engine.stats.add(key: key.name)

        var childContext = ctx

        childContext.parentUUID = ctx.selfUUID
        childContext.selfUUID = UUID().uuidString

        let span = startSpan(keyPrefix, ofKind: .client)

        span.attributes["trace.span_id"] = childContext.selfUUID
        span.attributes["trace.parent_id"] = childContext.parentUUID
        span.attributes["trace.trace_id"] = ctx.traceID

        return actualKey.computeValue(fxfi, childContext).flatMapError { underlyingError in
            let augmentedError: Swift.Error

            do {
                augmentedError = FXError.valueComputationError(
                    keyPrefix: keyPrefix,
                    key: encodedKey,
                    error: underlyingError,
                    requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot
                )
                span.recordError(underlyingError)
            } catch {
                augmentedError = FXError.keyEncodingError(
                    keyPrefix: FXCacheKeyPrefixMemoizer.get(for: actualKey),
                    encodingError: error,
                    underlyingError: underlyingError
                )
            }

            return ctx.group.next().makeFailedFuture(augmentedError)
        }.map { value in
            span.attributes["value"] = "\(value)"

            return InternalValue(value, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot)
        }.always { _ in
            span.attributes["keyPrefix"] = keyPrefix.description
            span.attributes["key"] = encodedKey.description

            fi.engine.stats.remove(key: key.name)
            span.end()
        }
    }

    func validateCache(key: InternalKey<K>, cached: InternalValue<K.ValueType>) -> Bool {
        return key.key.validateCache(cached: cached.value)
    }

    func fixCached(key: InternalKey<K>, value: InternalValue<K.ValueType>, _ fi: FunctionInterface, _ ctx: Context) -> LLBFuture<InternalValue<K.ValueType>?> {
        let actualKey = key.key

        let fxfi = FXFunctionInterface(actualKey, fi)
        return actualKey.fixCached(value: value.value, fxfi, ctx).map { maybeFixed in maybeFixed.map { InternalValue($0, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot) }}
    }
}

public protocol AsyncFXKey: FXKey {
    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType
    func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType?
}

extension AsyncFXKey {
    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType> {
        ctx.group.any().makeFutureWithTask {
            try await computeValue(fi, ctx)
        }
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType?> {
        ctx.group.any().makeFutureWithTask {
            try await fixCached(value: value, fi, ctx)
        }
    }

    public func fixCached(value: ValueType, _ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> ValueType? {
        return nil
    }
}

extension FXFunctionInterface {
    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) async throws -> X.ValueType {
        return try await request(x, requireCacheHit: requireCacheHit, ctx).get()
    }
}
