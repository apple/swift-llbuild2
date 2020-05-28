// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import NIO

/// Test implementation of a build engine to be used for inspection during tests. This class is a wrapper around an
/// actual LLBBuildEngine.
public class LLBTestBuildEngine {
    public let group: LLBFuturesDispatchGroup
    public let db: LLBTestCASDatabase
    public let executor: LLBTestExecutor

    private let engine: LLBBuildEngine

    init(group: LLBFuturesDispatchGroup? = nil, db: LLBTestCASDatabase? = nil, executor: LLBTestExecutor? = nil) {
        let group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        self.db = db ?? LLBTestCASDatabase(group: group)
        self.executor = executor ?? LLBTestExecutor(group: group)

        let engineContext = LLBBuildEngineContext(group: group, db: self.db, executor: self.executor)

        self.engine = LLBBuildEngine(engineContext: engineContext)
    }

    /// Requests the evaluation of a build key, returning an abstract build value.
    public func build(_ key: LLBBuildKey) -> LLBFuture<LLBBuildValue> {
        return self.engine.build(key)
    }

    /// Requests the evaluation of a build key and attempts to cast the resulting value to the specified type.
    public func build<V: LLBBuildValue>(_ key: LLBBuildKey, as valueType: V.Type = V.self) -> LLBFuture<V> {
        return self.engine.build(key)
    }
}
