// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

package struct UppercaseAction: AsyncFXAction, Encodable, Sendable {
    package typealias ValueType = UppercaseValue

    package static let version = 1
    package static let name = "UppercaseAction"

    package let input: String

    package var requirements: FXActionRequirements {
        FXActionRequirements(workerSize: .small)
    }

    package init(input: String) {
        self.input = input
    }

    package func run(_ ctx: Context) async throws -> UppercaseValue {
        return UppercaseValue(text: input.uppercased())
    }

    // MARK: - FXValue conformance

    package var refs: [LLBDataID] { [] }
    package var codableValue: UppercaseActionCodable { UppercaseActionCodable(input: input) }

    package init(refs: [LLBDataID], codableValue: UppercaseActionCodable) throws {
        self.init(input: codableValue.input)
    }
}

package struct UppercaseActionCodable: Codable, Sendable {
    package let input: String
}
