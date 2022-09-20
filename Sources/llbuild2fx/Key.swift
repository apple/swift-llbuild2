// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOConcurrencyHelpers
import TSCUtility
import llbuild2

public protocol FXKey: Encodable, FXVersioning {
    associatedtype ValueType: FXValue

    static var volatile: Bool { get }

    static var recomputeOnCacheFailure: Bool { get }

    // A concise, human readable contents summary that may be used in otherwise
    // hashed contexts (i.e. when stored in caches, etc.)
    var hint: String? { get }

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType>
}

extension FXKey {
    public static var volatile: Bool { false }

    public static var recomputeOnCacheFailure: Bool { true }

    public var hint: String? { nil }
}


extension FXKey {
    var internalKey: InternalKey<Self> {
        InternalKey(self)
    }
}

private struct FXCacheKeyPrefixMemoizer {
    private static let lock = Lock()
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

    init(_ key: K) {
        name = String(describing: K.self)
        self.key = key
    }

    private var hashData: Data {
        cachePath.data(using: .utf8)!
    }
}

extension InternalKey: FXKeyProperties {
    var volatile: Bool {
        K.volatile
    }

    var cachePath: String {
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
            return [basePath, String(data: json, encoding: .utf8)!].joined(separator: "/")
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
}

extension InternalKey: LLBKey {
    func hash(into hasher: inout Hasher) {
        hasher.combine(stableHashValue)
    }

    var hashValue: Int {
        var hasher = Hasher()
        self.hash(into: &hasher)
        return hasher.finalize()
    }

    func logDescription() -> String {
        debugDescription
    }
}

extension InternalKey: LLBStablyHashable {
    var stableHashValue: LLBDataID {
        let hashData = cachePath.data(using: .utf8)!
        return LLBDataID(blake3hash: ArraySlice(hashData))
    }
}

extension InternalKey: CustomDebugStringConvertible {
    var debugDescription: String {
        "KEY: //\(cachePath) [HASH: \(hashValue)]"
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
}


final class FXFunction<K: FXKey>: LLBTypedCachingFunction<InternalKey<K>, InternalValue<K.ValueType>> {

    override var recomputeOnCacheFailure: Bool { K.recomputeOnCacheFailure }

    override func compute(key: InternalKey<K>, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<
        InternalValue<K.ValueType>
    > {
        let actualKey = key.key

        ctx.fxBuildEngineStats.add(key: key.name)

        let fxfi = FXFunctionInterface(actualKey, fi)
        let value: LLBFuture<K.ValueType> = actualKey.computeValue(fxfi, ctx).flatMapError { underlyingError in
            let augmentedError: Swift.Error

            do {
                let keyData = try FXEncoder().encode(actualKey)
                let encodedKey = String(bytes: keyData, encoding: .utf8)!
                augmentedError = FXError.FXValueComputationError(
                    keyPrefix: FXCacheKeyPrefixMemoizer.get(for: actualKey),
                    key: encodedKey,
                    error: underlyingError,
                    requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot
                )
            } catch {
                augmentedError = FXError.FXKeyEncodingError(
                    keyPrefix: FXCacheKeyPrefixMemoizer.get(for: actualKey),
                    encodingError: error,
                    underlyingError: underlyingError
                )
            }

            return ctx.group.next().makeFailedFuture(augmentedError)
        }

        let encodedKey = (try? FXEncoder().encode(actualKey)) ?? Data()
        let buffer = LLBByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(encodedKey))
        let keyID = ctx.db.put(LLBCASObject(refs: [], data: buffer), ctx)

        return value.and(keyID).map { value, keyID in
            InternalValue(value, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot, keyID: keyID)
        }.always { _ in
            ctx.fxBuildEngineStats.remove(key: key.name)
        }
    }
}
