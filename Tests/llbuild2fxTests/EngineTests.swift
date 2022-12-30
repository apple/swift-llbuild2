// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import NIOCore
import TSFCAS
import TSFFutures
import llbuild2fx


public struct SumInput: Codable {
    public let values: [Int]

    public init(
        values: [Int]
    ) {
        self.values = values
    }
}

public struct SumOutput: Codable {
    public let total: Int
    public init(total: Int) {
        self.total = total
    }
}

extension SumOutput: FXValue {
    public var refs: [LLBDataID] { [] }
}

extension SumAction: FXAction {
    public var refs: [LLBDataID] { [] }
    public var codableValue: SumInput { input }

    public init(refs: [LLBDataID], codableValue: SumInput) throws {
        self.init(codableValue)
    }
}



public struct SumAction {
    let input: SumInput

    public init(_ input: SumInput) {
        self.input = input
    }

    public func run(_ ctx: Context) -> LLBFuture<SumOutput> {
        let total = input.values.reduce(0) { $0 + $1 }
        return ctx.group.next().makeSucceededFuture(SumOutput(total: total))
    }
}

extension SumAction: Encodable {}

public struct FakeExecutable: FXKey {
    public static var volatile: Bool { true }

    public let name: String
    public init(name: String) {
        self.name = name
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<FXExecutableID> {
        return ctx.group.next().makeSucceededFuture(FXExecutableID(dataID: LLBDataID()))
    }
}


public struct Sum: FXKey {
    public static let version = SumAction.version

    public static let versionDependencies: [FXVersioning.Type] = []

    public let values: [Int]

    public init(values: [Int]) {
        self.values = values
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<SumAction.ValueType> {
        let action = SumAction(SumInput(values: self.values))
        let exe = fi.request(FakeExecutable(name: "sum-task"), ctx)
        return fi.execute(action: action, with: exe, ctx)
    }
}



final class EngineTests: XCTestCase {
    func testBasicMath() throws {
        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()

        let engine = FXBuildEngine(group: group, db: db, functionCache: nil, executor: executor)

        let result = try engine.build(key: Sum(values: [2, 3, 4]), ctx).wait()
        XCTAssertEqual(result.total, 9)
    }
}
