// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import TSFCAS
import TSFFutures
@testable import llbuild2fx
import llbuild2Testing

// MARK: - Type conversion helpers (user-provided bridging)

extension FXDataID {
    init(fromTSF tsfID: LLBDataID) {
        self.init()
        self.bytes = tsfID.bytes
    }
}

extension LLBDataID {
    init(fromFX fxID: FXDataID) {
        self.init()
        self.bytes = fxID.bytes
    }
}

extension FXCASObject {
    init(fromTSF tsfObj: LLBCASObject) {
        self.init(refs: tsfObj.refs.map { FXDataID(fromTSF: $0) }, data: tsfObj.data)
    }
}

// MARK: - Conformance: LLBInMemoryCASDatabase → FXCASDatabase

extension LLBInMemoryCASDatabase: @retroactive FXCASDatabase {
    public func contains(_ id: FXDataID, _ ctx: Context) -> FXFuture<Bool> {
        return self.contains(LLBDataID(fromFX: id), ctx)
    }
    public func get(_ id: FXDataID, _ ctx: Context) -> FXFuture<FXCASObject?> {
        return self.get(LLBDataID(fromFX: id), ctx).map { $0.map { FXCASObject(fromTSF: $0) } }
    }
    public func identify(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        return self.identify(refs: refs.map { LLBDataID(fromFX: $0) }, data: data, ctx).map { FXDataID(fromTSF: $0) }
    }
    public func put(refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        return self.put(refs: refs.map { LLBDataID(fromFX: $0) }, data: data, ctx).map { FXDataID(fromTSF: $0) }
    }
    public func put(knownID id: FXDataID, refs: [FXDataID], data: FXByteBuffer, _ ctx: Context) -> FXFuture<FXDataID> {
        return self.put(knownID: LLBDataID(fromFX: id), refs: refs.map { LLBDataID(fromFX: $0) }, data: data, ctx).map { FXDataID(fromTSF: $0) }
    }
    public func supportedFeatures() -> FXFuture<FXCASFeatures> {
        return (self as LLBCASDatabase).supportedFeatures().map { tsfFeatures in
            FXCASFeatures(preservesIDs: tsfFeatures.preservesIDs)
        }
    }
}

// MARK: - Simple test key (defined here, visible to this test target)

struct InteropGreeting: AsyncFXKey, Sendable {
    typealias ValueType = InteropResult

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []
    static let actionDependencies: [any FXAction.Type] = []

    let name: String

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> InteropResult {
        return InteropResult(greeting: "Hello, \(name)!")
    }
}

struct InteropResult: FXValue, Equatable {
    let greeting: String

    var refs: [FXDataID] { [] }
    var codableValue: String { greeting }
    init(refs: [FXDataID], codableValue: String) {
        self.greeting = codableValue
    }
    init(greeting: String) {
        self.greeting = greeting
    }
}

// MARK: - Tests

final class TSFInteropTests: XCTestCase {
    func testTSFCASInterop() throws {
        let group = FXMakeDefaultDispatchGroup()
        let tsfDB = LLBInMemoryCASDatabase(group: group)

        let engine = FXEngine(
            group: group,
            db: tsfDB,
            functionCache: nil,
            executor: FXLocalExecutor()
        )

        let ctx = Context()
        let result = try engine.build(key: InteropGreeting(name: "Interop"), ctx).wait()
        XCTAssertEqual(result.greeting, "Hello, Interop!")
    }
}
