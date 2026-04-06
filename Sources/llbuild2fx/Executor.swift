// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCUtility

public protocol FXExecutor: Sendable {
    func perform<ActionType: FXAction>(
        _ action: ActionType,
        requirements: FXActionRequirements?,
        _ ctx: Context
    ) -> FXFuture<ActionType.ValueType>

    func cancel(
        _ buildID: FXBuildID,
        options: FXExecutorCancellationOptions,
        _ ctx: Context
    ) async throws
}

extension FXExecutor {
    func perform<ActionType: FXAction>(
        _ action: ActionType,
        _ ctx: Context
    ) -> FXFuture<ActionType.ValueType> {
        return perform(action, requirements: nil, ctx)
    }

    public func cancel(
        _ buildID: FXBuildID,
        options: FXExecutorCancellationOptions,
        _ ctx: Context
    ) async throws {
        // Do nothing by default.
    }
}

public struct FXExecutableID: FXSingleDataIDValue, FXFileID {
    public let dataID: FXDataID
    public init(dataID: FXDataID) {
        self.dataID = dataID
    }
}

public struct FXExecutorCancellationOptions {
    public var collectSysdiagnosis: Bool

    public init(collectSysdiagnosis: Bool = false) {
        self.collectSysdiagnosis = collectSysdiagnosis
    }
}
