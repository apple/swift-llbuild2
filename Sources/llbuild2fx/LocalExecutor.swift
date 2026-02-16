// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

public final class FXLocalExecutor: FXExecutor {
    public init() {}

    public func perform<ActionType: FXAction>(
        _ action: ActionType, requirements: FXActionRequirements?, _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        return action.run(ctx)
    }

    public func cancel(_ buildID: FXBuildID, options: FXExecutorCancellationOptions) async throws {
        // FIXME: Implement
    }
}
