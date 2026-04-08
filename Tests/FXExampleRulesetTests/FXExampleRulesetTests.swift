// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import NIOCore
import XCTest

import llbuild2Testing
import FXExampleRuleset
import llbuild2fx

final class FXExampleRulesetTests: XCTestCase {

    private func makeEngine(
        resources: [ResourceKey: FXResource] = [:],
        functionCache: (any FXFunctionCache<FXDataID>)? = nil,
        group: FXFuturesDispatchGroup? = nil
    ) -> (FXEngine<FXInMemoryCASDatabase>, FXFuturesDispatchGroup) {
        let group = group ?? FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let engine = FXEngine(
            group: group,
            db: db,
            functionCache: functionCache,
            executor: executor,
            resources: resources
        )
        return (engine, group)
    }

    // MARK: - Tests

    func testCasualGreeting() throws {
        let (engine, _) = makeEngine()
        let ctx = Context()

        let result = try engine.build(key: GreetingEntrypoint(name: "World"), ctx).wait()
        XCTAssertEqual(result.greeting, "HI, WORLD!")
    }

    func testFormalGreeting() throws {
        let resource = PrefixResource(prefix: "Dear", version: 1)
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]
        let (engine, _) = makeEngine(resources: resources)

        var ctx = Context()
        ctx.fxConfigurationInputs = ["greeting_style": "formal"]

        let result = try engine.build(key: GreetingEntrypoint(name: "World"), ctx).wait()
        XCTAssertEqual(result.greeting, "DEAR WORLD, WELCOME!")
    }

    func testResourceChangesPrefix() throws {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let functionCache = FXInMemoryFunctionCache<FXDataID>(group: group)
        let ctx = Context()

        // Build LookupPrefixKey with "Dear" prefix, version 1
        let resource1 = PrefixResource(prefix: "Dear", version: 1)
        let resources1: [ResourceKey: FXResource] = [.external(resource1.name): resource1]
        let engine1 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources1)

        let result1 = try engine1.build(key: LookupPrefixKey(), ctx).wait()
        XCTAssertEqual(result1.greeting, "Dear")

        // Same version, different prefix — should get cached result
        let resource2 = PrefixResource(prefix: "Hello", version: 1)
        let resources2: [ResourceKey: FXResource] = [.external(resource2.name): resource2]
        let engine2 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources2)

        let result2 = try engine2.build(key: LookupPrefixKey(), ctx).wait()
        XCTAssertEqual(result2.greeting, "Dear")

        // Bumped version — should recompute with new prefix
        let resource3 = PrefixResource(prefix: "Hello", version: 2)
        let resources3: [ResourceKey: FXResource] = [.external(resource3.name): resource3]
        let engine3 = FXEngine(group: group, db: db, functionCache: functionCache, executor: executor, resources: resources3)

        let result3 = try engine3.build(key: LookupPrefixKey(), ctx).wait()
        XCTAssertEqual(result3.greeting, "Hello")
        XCTAssertNotEqual(result1.greeting, result3.greeting)
    }

    func testDependencyGraph() throws {
        let resource = PrefixResource(prefix: "Dear", version: 1)
        let resources: [ResourceKey: FXResource] = [.external(resource.name): resource]
        let (engine, _) = makeEngine(resources: resources)
        let ctx = Context()

        // Test LookupPrefixKey directly
        let prefixResult = try engine.build(key: LookupPrefixKey(), ctx).wait()
        XCTAssertEqual(prefixResult.greeting, "Dear")

        // Test FormatGreetingKey with casual style (no resource lookup)
        let casualResult = try engine.build(key: FormatGreetingKey(name: "Alice", style: "casual"), ctx).wait()
        XCTAssertEqual(casualResult.greeting, "HI, ALICE!")

        // Test FormatGreetingKey with formal style (uses resource)
        let formalResult = try engine.build(key: FormatGreetingKey(name: "Alice", style: "formal"), ctx).wait()
        XCTAssertEqual(formalResult.greeting, "DEAR ALICE, WELCOME!")
    }

    func testCachingBehavior() throws {
        let group = FXMakeDefaultDispatchGroup()
        let functionCache = FXInMemoryFunctionCache<FXDataID>(group: group)
        let (engine, _) = makeEngine(functionCache: functionCache, group: group)
        let ctx = Context()

        let key = GreetingEntrypoint(name: "World")

        // First build
        let result1 = try engine.build(key: key, ctx).wait()
        XCTAssertEqual(result1.greeting, "HI, WORLD!")

        // Second build with same inputs — should produce same result (from cache)
        let result2 = try engine.build(key: key, ctx).wait()
        XCTAssertEqual(result1.greeting, result2.greeting)
    }
}
