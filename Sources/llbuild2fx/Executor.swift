// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCUtility
import TSFFutures

public protocol FXExecutor: Sendable {
    func perform<ActionType: FXAction>(
        _ action: ActionType,
        requirements: FXActionRequirements?,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType>

    func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment

    @available(*, deprecated, message: "use self-resolving perform")
    func perform<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment
}

extension FXExecutor {
    func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment {
        true
    }

    func perform<ActionType: FXAction>(
        _ action: ActionType,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        return perform(action, requirements: nil, ctx)
    }
}

public struct FXExecutableID: FXSingleDataIDValue, FXFileID {
    public let dataID: LLBDataID
    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}
