// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import TSCUtility
import llbuild2

public protocol FXKey: Encodable, FXVersioning {
    associatedtype ValueType: FXValue

    static var volatile: Bool { get }

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<ValueType>
}

extension FXKey {
    public static var volatile: Bool { false }
}


extension FXKey {
    var internalKey: InternalKey<Self> {
        InternalKey(self)
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
        let basePath = K.cacheKeyPrefix

        let asArgs = try! CommandLineArgsEncoder().encode(key)
        let argsKey = asArgs.joined(separator: " ")

        let keyLengthLimit = 250

        guard argsKey.count > keyLengthLimit else {
            return [basePath, argsKey].joined(separator: "/")
        }

        let json = try! FXEncoder().encode(key)
        guard json.count > keyLengthLimit else {
            return [basePath, String(data: json, encoding: .utf8)!].joined(separator: "/")
        }

        let hash = LLBDataID(blake3hash: ArraySlice<UInt8>(json))
        let str = ArraySlice(hash.bytes.dropFirst().prefix(9)).base64URL()
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

final class FXFunction<K: FXKey>: LLBTypedCachingFunction<InternalKey<K>, InternalValue<K.ValueType>> {
    enum Error: Swift.Error {
        case FXValueComputationError(keyPrefix: String, key: String, error: Swift.Error)
        case FXKeyEncodingError(keyPrefix: String, encodingError: Swift.Error, underlyingError: Swift.Error)
    }

    override func compute(key: InternalKey<K>, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<
        InternalValue<K.ValueType>
    > {
        let actualKey = key.key

        ctx.fxBuildEngineStats.add(key: key.name)

        let fxfi = FXFunctionInterface(actualKey, fi)
        return actualKey.computeValue(fxfi, ctx).flatMapError { underlyingError in
            let augmentedError: Swift.Error

            do {
                let keyData = try FXEncoder().encode(actualKey)
                let encodedKey = String(bytes: keyData, encoding: .utf8)!
                augmentedError = Error.FXValueComputationError(
                    keyPrefix: K.cacheKeyPrefix,
                    key: encodedKey,
                    error: underlyingError
                )
            } catch {
                augmentedError = Error.FXKeyEncodingError(
                    keyPrefix: K.cacheKeyPrefix,
                    encodingError: error,
                    underlyingError: underlyingError
                )
            }

            return ctx.group.next().makeFailedFuture(augmentedError)
        }.map { value in
            InternalValue(value, requestedCacheKeyPaths: fxfi.requestedCacheKeyPathsSnapshot)
        }.always { _ in
            ctx.fxBuildEngineStats.remove(key: key.name)
        }
    }
}
