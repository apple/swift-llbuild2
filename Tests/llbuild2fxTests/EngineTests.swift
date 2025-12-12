// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSFCAS
import TSFFutures
import XCTest

@testable import llbuild2fx

public struct SumInput: Codable, Sendable {
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

public struct Sum: FXKey {
    public static let version = SumAction.version

    public static let versionDependencies: [FXVersioning.Type] = []
    public static let actionDependencies: [any FXAction.Type] = [SumAction.self]

    public let values: [Int]

    public init(values: [Int]) {
        self.values = values
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<SumAction.ValueType> {
        let action = SumAction(SumInput(values: self.values))
        return fi.spawn(action, ctx)
    }
}


public struct AbsoluteSum: AsyncFXKey {
    public typealias ValueType = SumAction.ValueType

    public static let version = SumAction.version

    public static let versionDependencies: [FXVersioning.Type] = [Sum.self]

    public let values: [Int]

    public init(values: [Int]) {
        self.values = values
    }

    public func computeValue(_ fi: FXFunctionInterface<AbsoluteSum>, _ ctx: Context) async throws -> SumAction.ValueType {
        let sum = try await fi.request(Sum(values: self.values), ctx).total
        return SumOutput(total: sum < 0 ? sum * -1 : sum)
    }

    public func validateCache(cached: SumAction.ValueType) -> Bool {
        return cached.total >= 0
    }

    public func fixCached(value: SumAction.ValueType, _ fi: FXFunctionInterface<AbsoluteSum>, _ ctx: Context) async throws -> SumAction.ValueType? {
        if value.total < 0 {
            return SumAction.ValueType(total: value.total * -1)
        }

        return nil
    }
}

actor TestFunctionCache {
    private var cache: [String: LLBDataID] = [:]

    func get(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) async -> LLBDataID? {
        return cache[props.cachePath]
    }

    func update(key: FXRequestKey, props: FXKeyProperties, value: LLBDataID, _ ctx: Context) async {
        cache[props.cachePath] = value
    }
}

extension TestFunctionCache: FXFunctionCache {
    nonisolated func get(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) -> LLBFuture<LLBDataID?> {
        return ctx.group.any().makeFutureWithTask {
            return await self.get(key: key, props: props, ctx)
        }
    }

    nonisolated func update(key: FXRequestKey, props: FXKeyProperties, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void> {
        return ctx.group.any().makeFutureWithTask {
            _ = await self.update(key: key, props: props, value: value, ctx)
        }
    }
}

extension Int: @retroactive FXValue {}

final class EngineTests: XCTestCase {
    func testBasicMath() throws {
        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()

        let engine = FXEngine(group: group, db: db, functionCache: nil, executor: executor)

        let result = try engine.build(key: Sum(values: [2, 3, 4]), ctx).wait()
        XCTAssertEqual(result.total, 9)
    }

    func testWeirdMath() async throws {
        var ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = TestFunctionCache()
        ctx.db = db
        ctx.group = group

        let cachedOutput = SumOutput(total: -9)
        let cacheID = try await ctx.db.put(try cachedOutput.asCASObject(), ctx).get()

        let engine = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor)

        let internalKey = AbsoluteSum(values: [-2, -3, -4]).internalKey(engine, ctx)
        try await functionCache.update(key: internalKey, props: internalKey, value: cacheID, ctx).get()

        let result = try await engine.build(key: AbsoluteSum(values: [-2, -3, -4]), ctx).get()
        XCTAssertEqual(result.total, 9)
    }

    func testCycle() async throws {
        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()

        struct CyclicKey: FXKey {
            public static let version = 1
            public static let versionDependencies: [FXVersioning.Type] = []

            public let value: Int

            public init(value: Int) {
                self.value = value
            }

            public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<Int> {
                return fi.request(CyclicKey(value: value * -1), ctx)
            }
        }


        let engine = FXEngine(group: group, db: db, functionCache: nil, executor: executor)

        XCTAssertThrowsError(try engine.build(key: CyclicKey(value: 4), ctx).wait()) { error in
            guard case FXError.cycleDetected(let cycle) = unwrapFXError(error) else {
                XCTFail("Unexpected error type")
                return
            }
            XCTAssertEqual(cycle.count, 3)
        }
    }
}
