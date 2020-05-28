// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBExecutionProtocol

/// LLBBuildEngineContext contains references to dependencies that may need to be used throught the evaluation of the
/// functions.
public class LLBBuildEngineContext {
    /// The dispatch group to be used as when processing the future blocks throught the build.
    public let group: LLBFuturesDispatchGroup

    /// The CAS database reference to use for interfacing with CAS systems.
    public let db: LLBCASDatabase

    /// A reference to an executor that provides action execution support.
    public let executor: LLBExecutor

    public init(group: LLBFuturesDispatchGroup, db: LLBCASDatabase, executor: LLBExecutor) {
        self.group = group
        self.db = db
        self.executor = executor
    }
}
