// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Dispatch
import LLBBuildSystemProtocol

public typealias PreAction = (arguments: [String], environment: [String: String], background: Bool)

public enum RuleContextError: Error {
    case outputAlreadyRegistered
}

public class RuleContext {
    public let group: LLBFuturesDispatchGroup

    /// The label for the target being evaluated.
    public let label: Label

    typealias ActionOutputIndex = (actionIndex: Int, outputIndex: Int)

    // Map of declared short paths to declared artifacts from the rule. Use short path as the index since that's unique
    // on the rule evaluation context.
    var declaredArtifacts = [String: Artifact]()

    // Map of declared short path to
    var artifactActionMap = [String: ActionOutputIndex]()

    // List of registered actions.
    var registeredActions = [ActionKey]()

    // Private queue for concurrent access to the declared artifacts and actions.
    private let queue = DispatchQueue(label: "org.swift.llbuild2.rulecontext")

    private let configurationValue: ConfigurationValue

    init(group: LLBFuturesDispatchGroup, label: Label, configurationValue: ConfigurationValue) {
        self.group = group
        self.label = label
        self.configurationValue = configurationValue
    }

    /// Returns a the requested configuration fragment if available on the configuration, or nil otherwise.
    public func maybeGetFragment<C: LLBConfigurationFragment>(_ configurationType: C.Type = C.self) -> C? {
        if let fragment = try? getFragment(configurationType) {
            return fragment
        }
        return nil
    }

    /// Returns the requested configuration fragment or throws otherwise.
    public func getFragment<C: LLBConfigurationFragment>(_ configurationType: C.Type = C.self) throws -> C {
        return try configurationValue.get(configurationType)
    }

    /// Declares an output artifact from the target. If another artifact was declared with the same path, the same
    /// artifact instance will be returned (i.e. it is free to declare the same artifact path anywhere in the rule).
    public func declareArtifact(_ path: String) -> Artifact {
        return queue.sync {
            if let artifact = declaredArtifacts[path] {
                return artifact
            }
            let artifact = Artifact.derivedUninitialized(shortPath: path, root: label.asRoot)
            declaredArtifacts[path] = artifact
            return artifact
        }
    }

    /// Registers an action that takes the specified inputs and produces the specified outputs. Only a single action
    /// can be registered for each output, and each output declared from the rule must have 1 producing action. It is an
    /// error to leave an output artifact without a producing action, or to register more than one action for a
    /// particular output.
    public func registerAction(
        arguments: [String],
        environment: [String: String] = [:],
        inputs: [Artifact],
        outputs: [Artifact],
        workingDirectory: String? = nil,
        preActions: [PreAction] = []
    ) throws {
        try queue.sync {
            // Check that all outputs for the action are uninitialized, have already been declared (and correspond to
            // the declared one) and that they have not been associated to another action. If this turns out to be too
            // slow, we can store more runtime info and validate after rule evaluation is done.
            for output in outputs {
                guard output.originType == nil,
                      declaredArtifacts[output.shortPath] == output,
                      artifactActionMap[output.shortPath] == nil else {
                    throw RuleContextError.outputAlreadyRegistered
                }
            }

            let actionKey = ActionKey.command(
                actionSpec: LLBActionSpec(
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    preActions: preActions.map {
                        LLBPreActionSpec(arguments: $0.arguments, environment: $0.environment, background: $0.background)
                    }
                ),
                inputs: inputs,
                outputs: outputs.map { $0.asActionOutput() }
            )

            registeredActions.append(actionKey)
            let actionIndex = registeredActions.count - 1

            // Mark each of the outputs with the action and output index they were registered with.
            for (index, output) in outputs.enumerated() {
                artifactActionMap[output.shortPath] = ActionOutputIndex(actionIndex: actionIndex, outputIndex: index)
            }
        }
    }
}

extension Label {
    var asRoot: String {
        return (self.logicalPathComponents + [self.targetName]).joined(separator: "/")
    }
}
