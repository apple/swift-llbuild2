// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemProtocol

/// Implementation of an action executor to be used for test purposes.
public class LLBTestExecutor : LLBExecutor {
    let group: LLBFuturesDispatchGroup
    let executor: LLBExecutor?

    init(group: LLBFuturesDispatchGroup, executor: LLBExecutor?) {
        self.group = group
        self.executor = executor
    }

    public func execute(request: LLBActionExecutionRequest) -> LLBFuture<LLBActionExecutionResponse> {
        if let executor = executor {
            return executor.execute(request: request)
        }
        return group.next().makeFailedFuture(LLBExecutorError.unimplemented)
    }
}
