// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

public typealias LLBDynamicActionIdentifier = String

public protocol LLBDynamicActionExecutor {
    static var identifier: LLBDynamicActionIdentifier { get }

    func execute(
        request: LLBActionExecutionRequest,
        engineContext: LLBBuildEngineContext,
        _ fi: LLBDynamicFunctionInterface
    ) -> LLBFuture<LLBActionExecutionResponse>
}

public extension LLBDynamicActionExecutor {
    static var identifier: String {
        return String(describing: Self.self)
    }
}

public protocol LLBDynamicActionExecutorDelegate {
    func dynamicActionExecutor(for identifier: LLBDynamicActionIdentifier) -> LLBDynamicActionExecutor?
}

public protocol LLBDynamicFunctionInterface {
    func requestActionExecution(_ key: LLBActionExecutionKey) -> LLBFuture<LLBActionExecutionValue>
}
