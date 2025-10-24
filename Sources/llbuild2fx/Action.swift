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

public enum FXActionWorkerSize: Codable, Equatable {
    case small
    case large
}

public struct FXActionRequirements: Codable {
    public let workerSize: FXActionWorkerSize?
    public let allowNetworkAccess: Bool?
    public let requirements: [String: String]

    public init(
        workerSize: FXActionWorkerSize? = nil,
        allowNetworkAccess: Bool? = nil,
        _ requirements: [String: String] = [:]
    ) {
        self.workerSize = workerSize
        self.allowNetworkAccess = allowNetworkAccess
        self.requirements = requirements
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
    public var requirements: FXActionRequirements {
        return .init()
    }
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
