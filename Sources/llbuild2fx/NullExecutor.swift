// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

public final class FXNullExecutor: FXExecutor {
    public init() {}

    public func perform<ActionType: FXAction>(
        _ action: ActionType,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        return ctx.group.any().makeFailedFuture(Error.nullExecutor)
    }

    public func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment {
        false
    }

    enum Error: Swift.Error {
        case nullExecutor
    }

    public func perform<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment {
        return ctx.group.any().makeFailedFuture(Error.nullExecutor)
    }
}
