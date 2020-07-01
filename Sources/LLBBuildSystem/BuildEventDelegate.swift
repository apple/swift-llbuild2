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
    case success(LLBActionExecutionValue)

    /// The action failed. Read the stdoutID and stderrID for further information.
    case failure(stdoutID: LLBDataID, stderrID: LLBDataID)

    /// Unknown action failure.
    case unknownFailure
}

public protocol LLBBuildEventDelegate {
    /// Invoked when a target will start being evaluated.
    func targetEvaluationRequested(label: LLBLabel)

    /// Invoked when a target has completed evaluation.
    func targetEvaluationCompleted(label: LLBLabel)

    /// Invoked when an action is being requested.
    func actionRequested(actionKey: LLBActionExecutionKey)

    /// Invoked when an action has completed.
    func actionCompleted(actionKey: LLBActionExecutionKey, result: LLBActionResult)
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
