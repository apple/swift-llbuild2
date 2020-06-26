// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


/// Protocol definition for an executor that can fullfil action execution requests.
public protocol LLBExecutor {
    /// Requests the execution of an action, returning a future action response.
    func execute(request: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse>
}


public class LLBNullExecutor: LLBExecutor {
    public enum Error: Swift.Error {
        case actionExecutionUnsupported
    }
    public init() {}

    public func execute(request: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        return ctx.group.next().makeFailedFuture(Error.actionExecutionUnsupported)
    }
}
