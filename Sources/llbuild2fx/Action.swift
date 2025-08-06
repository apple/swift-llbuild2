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

public struct FXActionRequirements {
    public let predicate: (any Predicate)?

    public init(predicate: (any Predicate)? = nil) {
        self.predicate = predicate
    }
}

public protocol FXAction: FXValue {
    associatedtype ValueType: FXValue

    static var name: String { get }
    static var version: Int { get }

    var requirements: FXActionRequirements { get }

    func run(_ ctx: Context) -> LLBFuture<ValueType>
}

extension FXAction {
    public static var name: String { String(describing: self) }
    public static var version: Int { 0 }

    public var requirements: FXActionRequirements {
        FXActionRequirements()
    }
}

public protocol AsyncFXAction: FXAction {
    func run(_ ctx: Context) async throws -> ValueType
}

extension AsyncFXAction {
    public func run(_ ctx: Context) -> LLBFuture<ValueType> {
        ctx.group.any().makeFutureWithTask {
            try await run(ctx)
        }
    }
}
