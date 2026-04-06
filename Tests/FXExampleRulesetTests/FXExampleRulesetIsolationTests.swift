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

final class FXExampleRulesetIsolationTests: XCTestCase {

    func testGreetingEntrypointDelegatesToFormatKey() async throws {
        let engine = FXTestingEngine(overrides: [
            FXKeyTestOverride(FormatGreetingKey.self) { key in
                GreetingValue(greeting: "OVERRIDE_SENTINEL")
            },
        ])

        let result = try await engine.build(key: GreetingEntrypoint(name: "World"), Context())
        XCTAssertEqual(result.greeting, "OVERRIDE_SENTINEL")
    }

    func testFormatGreetingKeyCasualPath() async throws {
        // Override LookupPrefixKey — should NOT be called for casual style
        let engine = FXTestingEngine(overrides: [
            FXKeyTestOverride(LookupPrefixKey.self) { _ in
                XCTFail("LookupPrefixKey should not be called for casual style")
                return GreetingValue(greeting: "UNUSED")
            },
        ])

        let result = try await engine.build(
            key: FormatGreetingKey(name: "Alice", style: "casual"),
            Context()
        )
        // UppercaseAction runs normally via FXLocalExecutor
        XCTAssertEqual(result.greeting, "HI, ALICE!")
    }

    func testFormatGreetingKeyFormalPath() async throws {
        let engine = FXTestingEngine(overrides: [
            FXKeyTestOverride(LookupPrefixKey.self) { _ in
                GreetingValue(greeting: "Esteemed")
            },
        ])

        let result = try await engine.build(
            key: FormatGreetingKey(name: "Bob", style: "formal"),
            Context()
        )
        XCTAssertEqual(result.greeting, "ESTEEMED BOB, WELCOME!")
    }

    func testLookupPrefixKeyWithResource() async throws {
        let resource = PrefixResource(prefix: "Honorable", version: 1)
        let engine = FXTestingEngine(
            resources: [.external(resource.name): resource]
        )

        let result = try await engine.build(key: LookupPrefixKey(), Context())
        XCTAssertEqual(result.greeting, "Honorable")
    }

    func testOverrideReceivesCorrectKeyInstance() async throws {
        let expectation = XCTestExpectation(description: "Override called")

        var capturedName: String?
        var capturedStyle: String?

        let engine = FXTestingEngine(overrides: [
            FXKeyTestOverride(FormatGreetingKey.self) { key in
                capturedName = key.name
                capturedStyle = key.style
                expectation.fulfill()
                return GreetingValue(greeting: "test")
            },
        ])

        _ = try await engine.build(key: GreetingEntrypoint(name: "Charlie"), Context())

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(capturedName, "Charlie")
        XCTAssertEqual(capturedStyle, "casual")
    }
}
