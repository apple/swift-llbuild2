// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2fx
import NIOCore

public struct UppercaseAction: AsyncFXAction, Encodable, Sendable {
    public typealias ValueType = UppercaseValue

    public static let version = 1
    public static let name = "UppercaseAction"

    public let input: String

    public var requirements: FXActionRequirements {
        FXActionRequirements(workerSize: .small)
    }

    public init(input: String) {
        self.input = input
    }

    public func run(_ ai: FXActionInterface<FXDataID>, _ ctx: Context) async throws -> UppercaseValue
    {
        return UppercaseValue(text: input.uppercased())
    }

    // MARK: - FXValue conformance

    public var refs: [FXDataID] { [] }
    public var codableValue: UppercaseActionCodable { UppercaseActionCodable(input: input) }

    public init(refs: [FXDataID], codableValue: UppercaseActionCodable) throws {
        self.init(input: codableValue.input)
    }
}

public struct UppercaseActionCodable: Codable, Sendable {
    public let input: String
}
