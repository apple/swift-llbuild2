// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSCUtility
import TSFFutures

public enum FXActionWorkerSize: Equatable {
    case small
    case large
}

public struct FXActionRequirements {
    public let workerSize: FXActionWorkerSize?

    public init(workerSize: FXActionWorkerSize? = nil) {
        self.workerSize = workerSize
    }
}

public protocol FXAction: FXValue {
    associatedtype ValueType: FXValue

    static var name: String { get }
    static var version: Int { get }

    func run(_ ctx: Context) -> LLBFuture<ValueType>
}

extension FXAction {
    public static var name: String { String(describing: self) }
    public static var version: Int { 0 }
}

public protocol AsyncFXAction: FXAction {
    func run(_ ctx: Context) async throws -> ValueType
}

extension AsyncFXAction {
    public func run(_ ctx: Context) -> LLBFuture<ValueType> {
        TaskCancellationRegistry.makeCancellableTask({
            try await self.run(ctx)
        }, ctx)
    }
}
