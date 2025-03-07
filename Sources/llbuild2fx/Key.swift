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
import llbuild2
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


extension FXKey {
    func internalKey(_ ctx: Context) -> InternalKey<Self> {
        InternalKey(self, ctx)
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

final class InternalKey<K: FXKey> {
    let name: String
    let key: K
    private let ctx: Context
    let stableHashValue: LLBDataID
    let cachePath: String

    init(_ key: K, _ ctx: Context) {
        self.name = String(describing: K.self)
        self.key = key
        self.ctx = ctx
        let cachePath = Self.calculateCachePath(key: key, ctx: ctx)
        let hashData = Array(cachePath.utf8)
        self.stableHashValue = LLBDataID(blake3hash: hashData[...])
        self.cachePath = cachePath
    }
}

extension InternalKey: FXKeyProperties {
    var volatile: Bool {
        K.volatile
    }

    static func calculateCachePath(key: K, ctx: Context) -> String {
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

        let config = KeyConfiguration<K>(inputs: ctx.fxConfigurationInputs)
        guard !config.isNoop() else {
            return cachePathWithoutConfig()
        }
        return [cachePathWithoutConfig(), try! StringsEncoder().encode(config)[""]!].joined(separator: "/")
    }
}

extension InternalKey: LLBKey {
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

extension InternalKey: CustomDebugStringConvertible {
    var debugDescription: String {
        "KEY: //\(self.cachePath) [HASH: \(self.hashValue)]"
    }
}

extension InternalKey: FXFunctionProvider {
    func function() -> LLBFunction {
        FXFunction<K>()
    }
}

public enum FXError: Swift.Error {
    case FXValueComputationError(keyPrefix: String, key: String, error: Swift.Error, requestedCacheKeyPaths: FXSortedSet<String>)
    case FXKeyEncodingError(keyPrefix: String, encodingError: Swift.Error, underlyingError: Swift.Error)
    case FXMissingRequiredCacheEntry(cachePath: String)
}


public enum ParentUUIDKey { }

public enum SelfUUIDKey { }

private enum TraceIDKey { }

/// Support storing and retrieving a tracer instance from a Context.
public extension Context {
    public var parentUUID: String? {
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

    public var selfUUID: String? {
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

    public var traceID: String? {
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

final class FXFunction<K: FXKey>: LLBTypedCachingFunction<InternalKey<K>, InternalValue<K.ValueType>> {

    override var recomputeOnCacheFailure: Bool { K.recomputeOnCacheFailure }

    override func compute(key: InternalKey<K>, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<
        InternalValue<K.ValueType>
    > {
        let actualKey = key.key

        let fxfi = FXFunctionInterface(actualKey, fi)

        let keyData = try! FXEncoder().encode(actualKey)
        let encodedKey = String(bytes: keyData, encoding: .utf8)!
        let keyPrefix = FXCacheKeyPrefixMemoizer.get(for: actualKey)

        ctx.fxBuildEngineStats.add(key: key.name)

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
                augmentedError = FXError.FXValueComputationError(
                    keyPrefix: keyPrefix,
                    key: encodedKey,
                    error: underlyingError,
                    requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot
                )
                span.recordError(underlyingError)
            } catch {
                augmentedError = FXError.FXKeyEncodingError(
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

            ctx.fxBuildEngineStats.remove(key: key.name)
            span.end()
        }
    }

    override func validateCache(key: InternalKey<K>, cached: InternalValue<K.ValueType>) -> Bool {
        return key.key.validateCache(cached: cached.value)
    }

    override func fixCached(key: InternalKey<K>, value: InternalValue<K.ValueType>, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<InternalValue<K.ValueType>?> {
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
        do {
            return try await request(x, requireCacheHit: requireCacheHit, ctx).get()
        } catch let error as Error {
            switch error {
            case .missingRequiredCacheEntry(let cachePath):
                throw FXError.FXMissingRequiredCacheEntry(cachePath: cachePath)
            case .unexpressedKeyDependency, .executorCannotSatisfyRequirements, .noExecutable:
                throw error
            }
        }
    }
}
