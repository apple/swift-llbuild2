// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Logging
import NIOCore
import TSFCAS
import TSFFutures
import llbuild2

public final class FXBuildEngine {
    private let group: LLBFuturesDispatchGroup
    private let db: LLBCASDatabase
    private let cache: FXFunctionCache?
    private let executor: FXExecutor
    private let stats: FXBuildEngineStats
    private let logger: Logger?

    public init(
        group: LLBFuturesDispatchGroup,
        db: LLBCASDatabase,
        functionCache: FXFunctionCache?,
        executor: FXExecutor,
        stats: FXBuildEngineStats? = nil,
        logger: Logger? = nil
    ) {
        self.group = group
        self.db = db
        self.cache = functionCache
        self.executor = executor
        self.stats = stats ?? .init()
        self.logger = logger
    }

    private var engine: LLBEngine {
        let delegate = FXEngineDelegate()

        let functionCache: LLBFunctionCache?
        if let cache = self.cache {
            functionCache = FXFunctionCacheAdaptor(group: group, cache: cache)
        } else {
            functionCache = nil
        }

        return LLBEngine(
            group: group,
            delegate: delegate,
            db: db,
            functionCache: functionCache
        )
    }

    private func engineContext(_ ctx: Context) -> Context {
        var ctx = ctx

        ctx.fxExecutor = executor
        ctx.fxBuildEngineStats = stats

        if let logger = self.logger {
            ctx.logger = logger
        }
        return ctx
    }

    public func build<K: FXKey>(
        key: K,
        _ ctx: Context
    ) -> LLBFuture<K.ValueType> {
        let ctx = engineContext(ctx)
        return engine.build(key: key.internalKey(ctx), as: InternalValue<K.ValueType>.self, ctx).map { internalValue in
            internalValue.value
        }
    }
}
