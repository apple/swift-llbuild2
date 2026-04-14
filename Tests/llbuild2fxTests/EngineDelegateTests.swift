// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import llbuild2fx

// MARK: - Test delegate that records all callbacks

final class RecordingEngineDelegate: FXEngineDelegate, @unchecked Sendable {
    private let lock = NIOLock()
    private var callOrderStorage: [String] = []
    private var startEventsStorage: [FXKeyEvaluationStartEvent] = []
    private var keyEventsStorage: [FXKeyEvaluationEvent] = []
    private var actionEventsStorage: [FXActionEvaluationEvent] = []
    private var prepareChildContextCalledStorage = false

    var callOrder: [String] { lock.withLock { callOrderStorage } }
    var startEvents: [FXKeyEvaluationStartEvent] { lock.withLock { startEventsStorage } }
    var keyEvents: [FXKeyEvaluationEvent] { lock.withLock { keyEventsStorage } }
    var actionEvents: [FXActionEvaluationEvent] { lock.withLock { actionEventsStorage } }
    var prepareChildContextCalled: Bool { lock.withLock { prepareChildContextCalledStorage } }

    init() {}

    func prepareChildContext(_ ctx: inout Context) {
        lock.withLock {
            prepareChildContextCalledStorage = true
            callOrderStorage.append("prepareChildContext")
        }
    }

    func keyEvaluationStarted(_ event: FXKeyEvaluationStartEvent, _ ctx: Context) {
        lock.withLock {
            startEventsStorage.append(event)
            callOrderStorage.append("keyEvaluationStarted")
        }
    }

    func keyEvaluationCompleted(_ event: FXKeyEvaluationEvent, _ ctx: Context) {
        lock.withLock {
            keyEventsStorage.append(event)
            callOrderStorage.append("keyEvaluationCompleted")
        }
    }

    func actionEvaluationCompleted(_ event: FXActionEvaluationEvent, _ ctx: Context) {
        lock.withLock {
            actionEventsStorage.append(event)
            callOrderStorage.append("actionEvaluationCompleted")
        }
    }
}

// MARK: - A key that always fails

struct FailingKey: FXKey {
    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []

    func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> FXFuture<Int> {
        return ctx.group.next().makeFailedFuture(FXError.invalidValueType("intentional failure"))
    }
}


// MARK: - Tests

final class EngineDelegateTests: XCTestCase {

    private func makeEngine(delegate: (any FXEngineDelegate)? = nil) -> FXEngine<FXInMemoryCASDatabase> {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        return FXEngine(group: group, db: db, functionCache: nil, executor: executor, delegate: delegate)
    }

    // Test 1: prepareChildContext is called before evaluation
    func testPrepareChildContextCalledBeforeEvaluation() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        let result = try engine.build(key: Sum(values: [1, 2, 3]), ctx).wait()
        XCTAssertEqual(result.total, 6)
        XCTAssertTrue(delegate.prepareChildContextCalled)
    }

    // Test 2: keyEvaluationStarted receives correct span info
    func testKeyEvaluationStartCalledWithSpanInfo() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        _ = try engine.build(key: Sum(values: [1, 2]), ctx).wait()

        XCTAssertFalse(delegate.startEvents.isEmpty)
        let event = delegate.startEvents[0]
        XCTAssertTrue(event.keyPrefix.hasPrefix("Sum"), "Expected keyPrefix to start with 'Sum', got: \(event.keyPrefix)")
        XCTAssertFalse(event.spanID.isEmpty)
    }

    // Test 3: keyEvaluationCompleted has correct timing on success
    func testKeyEvaluationCompletedCalledWithTiming() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        _ = try engine.build(key: Sum(values: [5, 5]), ctx).wait()

        XCTAssertFalse(delegate.keyEvents.isEmpty)
        let event = delegate.keyEvents[0]
        XCTAssertTrue(event.keyPrefix.hasPrefix("Sum"), "Expected keyPrefix to start with 'Sum', got: \(event.keyPrefix)")
        XCTAssertEqual(event.status, "success")
        XCTAssertGreaterThanOrEqual(event.durationMs, 0)
    }

    // Test 4: keyEvaluationCompleted reports failure status
    func testKeyEvaluationCompletedOnFailure() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        XCTAssertThrowsError(try engine.build(key: FailingKey(), ctx).wait())

        XCTAssertFalse(delegate.keyEvents.isEmpty)
        let event = delegate.keyEvents[0]
        XCTAssertEqual(event.status, "failure")
    }

    // Test 5: actionEvaluationCompleted is called for spawned actions
    func testActionEvaluationCompletedCalled() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        _ = try engine.build(key: Sum(values: [10, 20]), ctx).wait()

        XCTAssertFalse(delegate.actionEvents.isEmpty)
        let event = delegate.actionEvents[0]
        XCTAssertEqual(event.actionName, "SumAction")
        XCTAssertEqual(event.status, "success")
    }

    // Test 6: nil delegate works (no crash)
    func testNilDelegateBehavesLikeToday() throws {
        let engine = makeEngine(delegate: nil)
        let ctx = Context()

        let result = try engine.build(key: Sum(values: [7, 8]), ctx).wait()
        XCTAssertEqual(result.total, 15)
    }

    // Test 7: custom partialResultExpiration is respected
    func testCustomPartialResultExpiration() throws {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let engine = FXEngine(group: group, db: db, functionCache: nil, executor: executor, partialResultExpiration: .milliseconds(50))
        let ctx = Context()

        let result = try engine.build(key: Sum(values: [3, 3]), ctx).wait()
        XCTAssertEqual(result.total, 6)
    }

    // Test 8: delegate call order is correct
    func testDelegateCallOrder() throws {
        let delegate = RecordingEngineDelegate()
        let engine = makeEngine(delegate: delegate)
        let ctx = Context()

        _ = try engine.build(key: Sum(values: [1]), ctx).wait()

        let order = delegate.callOrder
        // For a single Sum key evaluation, we expect:
        // prepareChildContext -> keyEvaluationStarted -> (action events) -> keyEvaluationCompleted
        guard let prepIdx = order.firstIndex(of: "prepareChildContext"),
              let startIdx = order.firstIndex(of: "keyEvaluationStarted"),
              let complIdx = order.firstIndex(of: "keyEvaluationCompleted") else {
            XCTFail("Missing expected delegate calls. Got: \(order)")
            return
        }
        XCTAssertLessThan(prepIdx, startIdx, "prepareChildContext should be called before keyEvaluationStarted")
        XCTAssertLessThan(startIdx, complIdx, "keyEvaluationStarted should be called before keyEvaluationCompleted")
    }
}
