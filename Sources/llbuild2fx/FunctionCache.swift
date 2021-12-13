// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Logging
import TSCUtility
import llbuild2

public protocol FXKeyProperties {
    var volatile: Bool { get }

    var cachePath: String { get }
}

public protocol FXFunctionCache {
    func get(key: LLBKey, props: FXKeyProperties, _ ctx: Context) -> LLBFuture<LLBDataID?>
    func update(key: LLBKey, props: FXKeyProperties, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void>
}

class FXFunctionCacheAdaptor: LLBFunctionCache {
    enum Error: Swift.Error {
        case notCachePathProvider(LLBKey)
    }

    private let group: LLBFuturesDispatchGroup
    private let cache: FXFunctionCache

    init(
        group: LLBFuturesDispatchGroup,
        cache: FXFunctionCache
    ) {
        self.group = group
        self.cache = cache
    }

    func get(key: LLBKey, _ ctx: Context) -> LLBFuture<LLBDataID?> {
        guard let props = key as? FXKeyProperties else {
            return group.next().makeFailedFuture(Error.notCachePathProvider(key))
        }
        return cache.get(key: key, props: props, ctx)
    }

    func update(key: LLBKey, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void> {
        guard let props = key as? FXKeyProperties else {
            ctx.logger?.trace("function cache: \(key) not cache path provider")
            return group.next().makeFailedFuture(Error.notCachePathProvider(key))
        }
        return cache.update(key: key, props: props, value: value, ctx)
    }
}
