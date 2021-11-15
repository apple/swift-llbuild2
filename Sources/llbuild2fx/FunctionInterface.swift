// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import llbuild2

private enum Error: Swift.Error {
    case missingRequiredCacheEntry(String)
    case unexpressedKeyDependency(from: String, to: String)
    case unexpressedKeyDependent(from: String, to: String)
}

public final class FXFunctionInterface<K: FXKey> {
    private let key: K
    private let fi: LLBFunctionInterface
    private var requestedKeyCachePaths = [String]()
    private let lock = Lock()
    var requestedCacheKeyPathsSnapshot: [String] {
        lock.withLock {
            requestedKeyCachePaths
        }
    }

    init(_ key: K, _ fi: LLBFunctionInterface) {
        self.key = key
        self.fi = fi
    }

    public func request<X: FXKey>(_ x: X, requireCacheHit: Bool = false, _ ctx: Context) -> LLBFuture<X.ValueType> {
        do {
            let kDesc = key.internalKey.logDescription()
            let realX = x.internalKey
            let xDesc = realX.logDescription()

            guard K.versionDependencies.contains(where: { $0 == X.self }) else {
                throw Error.unexpressedKeyDependency(
                    from: kDesc,
                    to: xDesc
                )
            }

            lock.withLock {
                requestedKeyCachePaths += [realX.cachePath]
            }

            let cacheCheck: LLBFuture<Void>
            if requireCacheHit {
                cacheCheck = self.fi.functionCache.get(key: realX, ctx).flatMapThrowing { maybeValue in
                    guard maybeValue != nil else {
                        throw Error.missingRequiredCacheEntry(realX.cachePath)
                    }

                    return
                }
            } else {
                cacheCheck = ctx.group.next().makeSucceededFuture(())
            }

            return cacheCheck.flatMap {
                self.fi.request(realX, as: InternalValue<X.ValueType>.self, ctx)
            }.map { internalValue in
                return internalValue.value
            }
        } catch {
            return ctx.group.next().makeFailedFuture(error)
        }
    }
}
