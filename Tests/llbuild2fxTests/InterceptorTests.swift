// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import llbuild2fx

final class EventLog: Sendable {
    private let storage = NIOLockedValueBox<[String]>([])

    func append(_ event: String) {
        storage.withLockedValue { $0.append(event) }
    }

    var events: [String] {
        storage.withLockedValue { $0 }
    }

    var context: Context {
        var ctx = Context()
        ctx.eventLog = self
        return ctx
    }
}

extension Context {
    fileprivate enum EventLogKey {}
    fileprivate enum MarkerKey {}

    fileprivate var eventLog: EventLog? {
        get { self[ObjectIdentifier(EventLogKey.self), as: EventLog.self] }
        set { self[ObjectIdentifier(EventLogKey.self)] = newValue }
    }

    fileprivate var marker: String? {
        get { self[ObjectIdentifier(MarkerKey.self), as: String.self] }
        set { self[ObjectIdentifier(MarkerKey.self)] = newValue }
    }
}

// Simulates an interceptor doing distributed tracing via Context.
struct ContextInjectingInterceptor: FXInterceptor {
    let keyInterceptor: Computation?

    init(marker: String) {
        self.keyInterceptor = Computation(marker: marker)
    }

    struct Computation: FXKeyInterceptor {
        let marker: String

        func computeValue<K: FXKey>(
            input: FXKeyInput<K>,
            next: (FXKeyInput<K>) async throws -> K.ValueType
        ) async throws -> K.ValueType {
            var input = input
            if let inherited = input.context.marker {
                input.context.marker = "\(inherited)>\(marker)"
            } else {
                input.context.marker = marker
            }
            return try await next(input)
        }
    }
}

// Simulates an interceptor calling `withSpan` from swift-distributed-tracing.
struct TaskLocalInjectingInterceptor: FXInterceptor {
    @TaskLocal static var boundMarker: String?

    let keyInterceptor: Computation?

    init(marker: String) {
        self.keyInterceptor = Computation(marker: marker)
    }

    struct Computation: FXKeyInterceptor {
        let marker: String

        func computeValue<K: FXKey>(
            input: FXKeyInput<K>,
            next: (FXKeyInput<K>) async throws -> K.ValueType
        ) async throws -> K.ValueType {
            let nested: String
            if let inherited = TaskLocalInjectingInterceptor.boundMarker {
                nested = "\(inherited)>\(marker)"
            } else {
                nested = marker
            }

            // Simulates calling `withSpan` from swift-distributed-tracing
            return try await TaskLocalInjectingInterceptor.$boundMarker.withValue(nested) {
                try await next(input)
            }
        }
    }
}

// A key that records how it was called.
struct RecordingKey: AsyncFXKey {
    struct RecordingOutput: FXValue, Codable {
        let marker: String?
        let taskLocalMarker: String?
    }

    typealias ValueType = RecordingOutput

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []

    func computeValue(_ fi: FXFunctionInterface<RecordingKey>, _ ctx: Context) async throws -> RecordingOutput {
        ctx.eventLog?.append("body")
        return RecordingOutput(
            marker: ctx.marker,
            taskLocalMarker: TaskLocalInjectingInterceptor.boundMarker
        )
    }
}

// A key that always throws an error.
struct ThrowingKey: AsyncFXKey {
    typealias ValueType = SumOutput

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = []

    struct Failure: Error {}

    func computeValue(_ fi: FXFunctionInterface<ThrowingKey>, _ ctx: Context) async throws -> SumOutput {
        throw Failure()
    }
}

// A key that requests RecordingKey and returns what it recorded.
struct RequestingKey: AsyncFXKey {
    typealias ValueType = RecordingKey.RecordingOutput

    static let version = 1
    static let versionDependencies: [FXVersioning.Type] = [RecordingKey.self]

    func computeValue(_ fi: FXFunctionInterface<RequestingKey>, _ ctx: Context) async throws -> RecordingKey.RecordingOutput {
        try await fi.request(RecordingKey(), ctx)
    }
}

// An interceptor that logs before / after the computation in an EventLog.
struct RecordingInterceptor: FXInterceptor {
    let keyInterceptor: Computation?

    init(name: String) {
        self.keyInterceptor = Computation(name: name)
    }

    struct Computation: FXKeyInterceptor {
        let name: String

        func computeValue<K: FXKey>(
            input: FXKeyInput<K>,
            next: (FXKeyInput<K>) async throws -> K.ValueType
        ) async throws -> K.ValueType {
            let log = input.context.eventLog!
            log.append("\(name)-before")
            do {
                let value = try await next(input)
                log.append("\(name)-after")
                return value
            } catch {
                log.append("\(name)-caught(\(type(of: error)))")
                throw error
            }
        }
    }
}

final class InterceptorTests: XCTestCase {

    private func makeEngine(_ interceptors: [any FXInterceptor]) -> FXEngine<FXInMemoryCASDatabase> {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        return FXEngine(
            group: group,
            db: db,
            functionCache: nil,
            executor: FXLocalExecutor(),
            interceptors: interceptors
        )
    }

    func testInterceptorsWrapComputation() async throws {
        let log = EventLog()
        let engine = makeEngine([
            RecordingInterceptor(name: "a"),
            RecordingInterceptor(name: "b"),
        ])

        _ = try await engine.build(key: RecordingKey(), log.context).get()

        XCTAssertEqual(log.events, ["a-before", "b-before", "body", "b-after", "a-after"])
    }

    func testForwardedContextReachesKeyBody() async throws {
        let engine = makeEngine([ContextInjectingInterceptor(marker: "injected")])
        let result = try await engine.build(key: RecordingKey(), Context()).get()
        XCTAssertEqual(result.marker, "injected")
    }

    func testTaskLocalReachesKeyBody() async throws {
        let engine = makeEngine([TaskLocalInjectingInterceptor(marker: "bound")])
        let result = try await engine.build(key: RecordingKey(), Context()).get()
        XCTAssertEqual(result.taskLocalMarker, "bound")
    }

    func testInterceptorNotInvokedForRepeatRequests() async throws {
        let log = EventLog()
        let engine = makeEngine([RecordingInterceptor(name: "a")])
        let ctx = log.context
        let key = RecordingKey()

        // The interceptor is meant to capture the actual evaluation, which happens only once. The
        // second call is served from the engine's internal cache and should not be intercepted.
        _ = try await engine.build(key: key, ctx).get()
        _ = try await engine.build(key: key, ctx).get()

        XCTAssertEqual(log.events, ["a-before", "body", "a-after"])
    }

    func testTaskLocalsPropagateToChildKey() async throws {
        let engine = makeEngine([
            ContextInjectingInterceptor(marker: "injected"),
            TaskLocalInjectingInterceptor(marker: "bound"),
        ])

        let result = try await engine.build(key: RequestingKey(), Context()).get()

        // RequestingKey uses RecordingKey, so the interceptor is called twice.
        XCTAssertEqual(result.marker, "injected>injected")
        XCTAssertEqual(result.taskLocalMarker, "bound>bound")
    }

    func testInterceptorCatchesOriginalError() async throws {
        let log = EventLog()
        let engine = makeEngine([RecordingInterceptor(name: "a")])

        do {
            _ = try await engine.build(key: ThrowingKey(), log.context).get()
            XCTFail("expected the build to fail")
        } catch {}

        // The interceptor caught the real error, not FXError.valueComputationError
        XCTAssertEqual(log.events, ["a-before", "a-caught(Failure)"])
    }
}
