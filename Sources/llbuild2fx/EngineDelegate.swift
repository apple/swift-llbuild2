// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch
import Foundation

// MARK: - Evaluation events

/// Information about a key evaluation that is about to start.
public struct FXKeyEvaluationStartEvent: Sendable {
    public let keyPrefix: String
    public let encodedKey: String
    public let spanID: String
    public let parentSpanID: String?
    public let telemetryLabel: String
}

/// Information about a completed key evaluation.
public struct FXKeyEvaluationEvent: Sendable {
    public let keyPrefix: String
    public let encodedKey: String
    public let spanID: String
    public let parentSpanID: String?
    public let durationMs: Int
    public let status: String       // "success" or "failure"
    public let startTime: Date
    public let telemetryLabel: String
}

/// Information about a completed action execution.
public struct FXActionEvaluationEvent: Sendable {
    public let actionName: String
    public let spanID: String
    public let parentSpanID: String?
    public let durationMs: Int
    public let status: String       // "success" or "failure"
    public let startTime: Date
}

// MARK: - Delegate protocol

/// Protocol for services to customize FXEngine behavior — context preparation,
/// telemetry/tracing hooks, and partial-result cache lifetime.
///
/// Each service provides its own conformance
public protocol FXEngineDelegate: Sendable {
    /// Called after creating the child context but before ``FXKey/computeValue``.
    /// Use to propagate span IDs, set up tracing parents, etc.
    func prepareChildContext(_ ctx: inout Context)

    /// Called just before key evaluation begins. Emit trace start events here.
    /// The matching end event comes from ``keyEvaluationCompleted(_:_:)``.
    func keyEvaluationStarted(_ event: FXKeyEvaluationStartEvent, _ ctx: Context)

    /// Called after key evaluation completes (success or failure).
    func keyEvaluationCompleted(_ event: FXKeyEvaluationEvent, _ ctx: Context)

    /// Called after action execution completes (success or failure).
    func actionEvaluationCompleted(_ event: FXActionEvaluationEvent, _ ctx: Context)
}
