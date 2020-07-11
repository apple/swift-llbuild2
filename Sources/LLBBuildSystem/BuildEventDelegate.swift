// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import TSCUtility

public enum LLBActionResult {
    /// The action was successful.
    case success

    /// The action failed. Read the stdoutID and stderrID for further information.
    case failure(stdoutID: LLBDataID, stderrID: LLBDataID)

    /// Unknown action failure.
    case unknownFailure
}

public protocol LLBBuildEventPreAction {
    var arguments: [String] { get }
}

public protocol LLBBuildEventActionDescription {
    var identifier: String { get }
    var arguments: [String] { get }
    var environment: [String: String] { get }
    var preActions: [LLBBuildEventPreAction] { get }
    var mnemonic: String { get }
}

public extension LLBBuildEventActionDescription {
    var identifier: String {
        get {
            var hasher = Hasher()
            arguments.hash(into: &hasher)
            environment.hash(into: &hasher)
            preActions.forEach {
                $0.arguments.hash(into: &hasher)
            }
            mnemonic.hash(into: &hasher)
            let value = hasher.finalize()
            return "\(value * value.signum())"
        }
    }
}

public protocol LLBBuildEventDelegate {
    /// Invoked when a target will start being evaluated.
    func targetEvaluationRequested(label: LLBLabel)

    /// Invoked when a target has completed evaluation.
    func targetEvaluationCompleted(label: LLBLabel)

    /// Invoked when an action has been scheduled.
    func actionScheduled(action: LLBBuildEventActionDescription)

    /// Invoked when an action has completed.
    func actionCompleted(action: LLBBuildEventActionDescription)

    /// Invoked when an action is starting execution.
    func actionExecutionStarted(action: LLBBuildEventActionDescription)

    /// Invoked when an action has completed.
    func actionExecutionCompleted(action: LLBBuildEventActionDescription, result: LLBActionResult)
}

/// Support storing and retrieving a build event delegate instance from a Context.
public extension Context {
    var buildEventDelegate: LLBBuildEventDelegate? {
        get {
            guard let delegate = self[ObjectIdentifier(LLBBuildEventDelegate.self)] as? LLBBuildEventDelegate else {
                return nil
            }
            return delegate
        }
        set {
            self[ObjectIdentifier(LLBBuildEventDelegate.self)] = newValue
        }
    }
}
