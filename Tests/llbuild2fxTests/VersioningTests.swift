//
//  VersioningTests.swift
//  llbuild2
//
//  Created by David Bryson on 5/14/25.
//

import XCTest

@testable import llbuild2fx

struct ExampleActionResult: Codable, Sendable {
}

extension ExampleActionResult: FXValue {
    public typealias CodableValueType = String
    public var refs: [TSFCAS.LLBDataID] { [] }

    public var codableValue: String { return String() }

    public init(refs: [TSFCAS.LLBDataID], codableValue: String) throws {
    }
}

struct ExampleAction: AsyncFXAction {
    typealias ValueType = ExampleActionResult

    func run(_ ctx: Context) async throws -> ExampleActionResult {
        return ExampleActionResult()
    }
}

extension ExampleAction: FXValue {
    typealias CodableValueType = String
    var refs: [TSFCAS.LLBDataID] { [] }

    var codableValue: String { return String() }

    public init(refs: [TSFCAS.LLBDataID], codableValue: String) throws {
    }
}

extension String: @retroactive FXValue {

}


struct Hello: AsyncFXKey {
    typealias ValueType = String

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []
    static let actionDependencies: [any FXAction.Type] = [ExampleAction.self]
    static let resourceEntitlements: [ResourceKey] = []

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> String {
        _ = try await fi.spawn(ExampleAction(), ctx)
        return String()
    }
}

struct World: AsyncFXKey {
    typealias ValueType = String

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []
    static let actionDependencies: [any FXAction.Type] = [ExampleAction.self]
    static let resourceEntitlements: [ResourceKey] = []

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> String {
        _ = try await fi.spawn(ExampleAction(), ctx)
        return String()
    }
}

struct Concat: AsyncFXKey {
    typealias ValueType = String

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = [Hello.self, World.self]
    static let resourceEntitlements: [ResourceKey] = []

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> String {
        async let helloResult = fi.request(Hello(), ctx)
        async let worldResult = fi.request(World(), ctx)

        return "\(try await helloResult) \(try await worldResult)!"
    }
}


final class VersioningTests: XCTestCase {
    func testAggregatedVersion() {
        XCTAssertEqual(Concat.aggregatedVersion, 3)
    }

    func testAggregatedActionDependencies() {
        let actionDeps = Concat.aggregatedActionDependencies
        XCTAssertEqual(actionDeps.count, 1)
        XCTAssertNotNil(actionDeps[0] as? ExampleAction.Type)
    }
}
