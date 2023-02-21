// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Crypto
import TSCUtility

public enum LLBActionResult {
    /// The action was successful.
    case success(stdoutID: LLBDataID)

    /// The action failed. Read the stdoutID and stderrID for further information.
    case failure(error: Error)
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
    var description: String { get }
    var owner: LLBLabel? { get }
}

public extension LLBBuildEventActionDescription {
    var identifier: String {
        get {
            var hashFunction = Crypto.SHA256()
            arguments.forEach { hashFunction.update(data: $0.data(using: .utf8)!) }
            environment.sorted(by: <).forEach { (key, value) in
                hashFunction.update(data: key.data(using: .utf8)!)
                hashFunction.update(data: value.data(using: .utf8)!)
            }
            preActions.forEach { preAction in
                preAction.arguments.forEach {
                    hashFunction.update(data: $0.data(using: .utf8)!)
                }
            }
            hashFunction.update(data: mnemonic.data(using: .utf8)!)
            hashFunction.update(data: description.data(using: .utf8)!)

            if let owner = owner {
                owner.logicalPathComponents.forEach {
                    hashFunction.update(data: $0.data(using: .utf8)!)
                }
                hashFunction.update(data: owner.targetName.data(using: .utf8)!)
            }

            let digest = hashFunction.finalize()

            return ArraySlice(digest).base64URL()
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
    func actionCompleted(action: LLBBuildEventActionDescription, result: LLBActionResult)

    /// Invoked when an action is starting execution.
    func actionExecutionStarted(action: LLBBuildEventActionDescription)

    /// Invoked when an action has completed.
    func actionExecutionCompleted(action: LLBBuildEventActionDescription)
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
