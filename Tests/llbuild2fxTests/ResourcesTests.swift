// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCBasic
import TSFCAS
import TSFFutures
import XCTest

@testable import llbuild2fx

class StatefulResource<T>: FXResource {
    var name: String
    let version: Int?
    let lifetime: ResourceLifetime

    var state: T

    init(initialState: T, lifetime: ResourceLifetime, version: Int? = nil, name: String = "StatefulResource<\(String(describing: T.self))>") {
        self.name = name
        self.state = initialState
        self.lifetime = lifetime
        self.version = version
    }
}


final class ResourcesTests: XCTestCase {
    func testIdempotentResource() throws {
        struct ReadResource: AsyncFXKey {
            public typealias ValueType = Int

            public static let version = 1
            public static let versionDependencies: [FXVersioning.Type] = []
            public static let resourceEntitlements: [ResourceKey] = [
                .external("testresource")
            ]

            public func computeValue(_ fi: llbuild2fx.FXFunctionInterface<Self>, _ ctx: Context) async throws -> Int {
                guard let resource: StatefulResource<Int> = fi.resource(.external("testresource")) else {
                    throw StringError("resource not found")
                }

                return resource.state
            }
        }

        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = FXInMemoryFunctionCache(group: group)

        let resource = StatefulResource<Int>(initialState: 10, lifetime: .idempotent, name: "testresource")
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]

        let engine = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources)

        let result = try engine.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result, resource.state)

        // Check if we mutate that state that the value remains cached
        resource.state = 12
        let result2 = try engine.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result, result2)
    }

    func testUnentitledResource() throws {
        enum Error: Swift.Error {
            case resourceNotFound
        }
        struct BadReadResource: AsyncFXKey {
            public typealias ValueType = Int

            public static let version = 1
            public static let versionDependencies: [FXVersioning.Type] = []
            public static let resourceEntitlements: [ResourceKey] = []

            public func computeValue(_ fi: llbuild2fx.FXFunctionInterface<Self>, _ ctx: Context) async throws -> Int {
                guard let resource: StatefulResource<Int> = fi.resource(.external("testresource")) else {
                    throw Error.resourceNotFound
                }

                return resource.state
            }
        }

        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = FXInMemoryFunctionCache(group: group)

        let resource = StatefulResource<Int>(initialState: 10, lifetime: .idempotent, name: "testresource")
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]

        let engine = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources)

        XCTAssertThrowsError(try engine.build(key: BadReadResource(), ctx).wait()) { error in
            guard case Error.resourceNotFound = unwrapFXError(error) else {
                XCTFail("accessed unentitled resource")
                return
            }
        }
    }


    func testVersionedResource() throws {
        struct ReadResource: AsyncFXKey {
            public typealias ValueType = Int

            public static let version = 1
            public static let versionDependencies: [FXVersioning.Type] = []
            public static let resourceEntitlements: [ResourceKey] = [
                .external("testresource")
            ]

            public func computeValue(_ fi: llbuild2fx.FXFunctionInterface<Self>, _ ctx: Context) async throws -> Int {
                guard let resource: StatefulResource<Int> = fi.resource(.external("testresource")) else {
                    throw StringError("resource not found")
                }

                return resource.state
            }
        }

        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = FXInMemoryFunctionCache(group: group)

        let resource = StatefulResource<Int>(initialState: 10, lifetime: .versioned, version: 1, name: "testresource")
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]

        let engine = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources)

        let result = try engine.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result, resource.state)

        // Check if we mutate that state, but not version, that the value remains cached
        let resource2 = StatefulResource<Int>(initialState: 12, lifetime: .versioned, version: 1, name: "testresource")
        let resources2: [ResourceKey: FXResource] = [.external(resource2.name): resource2]
        let engine2 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources2)
        let result2 = try engine2.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result, result2)

        // Check
        let resource3 = StatefulResource<Int>(initialState: 12, lifetime: .versioned, version: 2, name: "testresource")
        let resources3: [ResourceKey: FXResource] = [.external(resource3.name): resource3]
        let engine3 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources3)
        let result3 = try engine3.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(resource3.state, result3)
        XCTAssertNotEqual(result, result3)
    }

    func testRequestOnlyResource() throws {
        struct ReadResource: AsyncFXKey {
            public typealias ValueType = Int

            public static let version = 1
            public static let versionDependencies: [FXVersioning.Type] = []
            public static let resourceEntitlements: [ResourceKey] = [
                .external("testresource")
            ]

            public func computeValue(_ fi: llbuild2fx.FXFunctionInterface<Self>, _ ctx: Context) async throws -> Int {
                guard let resource: StatefulResource<Int> = fi.resource(.external("testresource")) else {
                    throw StringError("resource not found")
                }

                return resource.state
            }
        }

        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        let db = LLBInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = FXInMemoryFunctionCache(group: group)

        let resource = StatefulResource<Int>(initialState: 10, lifetime: .requestOnly, name: "testresource")
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]

        let engine1 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources)

        let result1 = try engine1.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result1, resource.state)

        // Check if we mutate that state, a new engine gets it
        resource.state = 12

        let engine2 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources)
        let result2 = try engine2.build(key: ReadResource(), ctx).wait()
        XCTAssertEqual(result2, resource.state)

        // Check if we recreate the same buildID, we get the old cached value
        let engine3 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources, buildID: engine1.buildID)
        let result3 = try engine3.build(key: ReadResource(), ctx).wait()
        XCTAssertNotEqual(result3, resource.state)
        XCTAssertEqual(result1, result3)
    }

}
