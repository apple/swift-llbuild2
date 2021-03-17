// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Dispatch
import Foundation

public typealias LLBPreAction = (arguments: [String], environment: [String: String], background: Bool)

public enum LLBRuleContextError: Error {
    case outputAlreadyRegistered
    case writeError
    case invalidRedeclarationOfArtifact(existing: LLBArtifact, new: LLBArtifactType)
    case missingDependencyName
    case dependencyTypeMismatch
    case mergeDirectoriesIntoFileError
    case chainedInputNotInInputs
}

/// Helper storage for the provider maps that preserves the original type of dependency.
fileprivate enum RuleContextTargetDependencyType {
    case single(LLBProviderMap)
    case list([LLBProviderMap])

    init?(_ namedConfiguredTargetDependency: LLBNamedConfiguredTargetDependency) {
        switch namedConfiguredTargetDependency.type {

        case .single:
            // FIXME: We should validate that there is 1 and only 1 providerMap. This is sort of managed by
            // LLBBuildSystem, so it shouldn't happen that we get 0 or more than 1 provider maps here.
            self = .single(namedConfiguredTargetDependency.providerMaps[0])
        case .list:
            self = .list(namedConfiguredTargetDependency.providerMaps)
        default:
            return nil
        }
    }
}

public class LLBRuleContext {

    /// The global context.
    public let ctx: Context

    public var group: LLBFuturesDispatchGroup { ctx.group }

    /// The label for the target being evaluated.
    public let label: LLBLabel

    /// The execution relative path where declared artifacts are expected.
    public let outputsDirectory: String

    typealias ActionOutputIndex = (actionIndex: Int, outputIndex: Int)

    // Map of declared short paths to declared artifacts from the rule. Use short path as the index since that's unique
    // on the rule evaluation context.
    var declaredArtifacts = [String: LLBArtifact]()

    // List of registered actions.
    var registeredActions = [LLBActionKey]()

    // Map of artifact to static contents that rule evaluations may have requested.
    var staticWriteActions = [String: Data]()

    // Private queue for concurrent access to the declared artifacts and actions.
    private let queue = DispatchQueue(label: "org.swift.llbuild2.rulecontext")

    private let configurationValue: LLBConfigurationValue

    // Private reference to the artifact owner ID to associate in ArtifactOwners.
    private let artifactOwnerID: LLBDataID

    private let targetDependencies: [String: RuleContextTargetDependencyType]

    private let artifactRoots: [String]

    /// The function interface for evaluating requests.
    ///
    /// Note: This should be only used for complex rule implementations. Most rule implementations
    /// should not need to evaluate functions on the fly.
    public let fi: LLBBuildFunctionInterface

    init(
        ctx: Context,
        label: LLBLabel,
        configurationValue: LLBConfigurationValue,
        artifactOwnerID: LLBDataID,
        targetDependencies: [LLBNamedConfiguredTargetDependency],
        fi: LLBBuildFunctionInterface
    ) {
        self.ctx = ctx
        self.label = label
        self.configurationValue = configurationValue
        self.artifactOwnerID = artifactOwnerID
        self.fi = fi

        if configurationValue.root.isEmpty {
            self.artifactRoots = [label.asRoot]
        } else {
            self.artifactRoots = [configurationValue.root, label.asRoot]
        }

        self.outputsDirectory = self.artifactRoots.joined(separator: "/")

        self.targetDependencies = targetDependencies.reduce(into: [:]) { (dict, entry) in
            switch entry.type {
            case .single:
                dict[entry.name] = .single(entry.providerMaps[0])
            case .list:
                dict[entry.name] = .list(entry.providerMaps)
            default:
                fatalError("Unexpected, since this is entirely controlled by llbuild2")
            }
        }
    }

    /// Returns the provider of the specified type, for the given dependency name, or throws if none exists. This API
    /// enforces that the dependency type was declared as a single dependency.
    public func getProvider<P: LLBProvider>(for name: String, as providerType: P.Type = P.self) throws -> P {
        guard let dependencyEntry = targetDependencies[name] else {
            throw LLBRuleContextError.missingDependencyName
        }

        guard case let .single(providerMap) = dependencyEntry else {
            throw LLBRuleContextError.dependencyTypeMismatch
        }

        // This is so cool, type inference FTW.
        return try providerMap.get()
    }

    /// Returns the providers of the specified type, for the given dependency name, or throws if any of the dependencies
    /// does not provide the requested provider.
    public func getProviders<P: LLBProvider>(for name: String, as providerType: P.Type = P.self) throws -> [P] {
        guard let dependencyEntry = targetDependencies[name] else {
            throw LLBRuleContextError.missingDependencyName
        }

        guard case let .list(providerMaps) = dependencyEntry else {
            throw LLBRuleContextError.dependencyTypeMismatch
        }

        return try providerMaps.map { try $0.get() }
    }

    /// Returns the provider of the specified type, for the given dependency name, or nil if none exists. This API
    /// enforces that the dependency type was declared as a single dependency.
    public func getOptionalProvider<P: LLBProvider>(for name: String, as providerType: P.Type = P.self) throws -> P? {
        guard let dependencyEntry = targetDependencies[name] else {
            throw LLBRuleContextError.missingDependencyName
        }

        guard case let .single(providerMap) = dependencyEntry else {
            throw LLBRuleContextError.dependencyTypeMismatch
        }

        // This is so cool, type inference FTW.
        return try providerMap.getOptional()
    }

    /// Returns the providers of the specified type, for the given dependency name, if the dependency provides the
    /// provider. If no dependency provides the provider, returns an empty list. This API enforces that the dependency
    /// type was declared as a list.
    public func getOptionalProviders<P: LLBProvider>(for name: String, as providerType: P.Type = P.self) throws -> [P] {
        guard let dependencyEntry = targetDependencies[name] else {
            throw LLBRuleContextError.missingDependencyName
        }

        guard case let .list(providerMaps) = dependencyEntry else {
            throw LLBRuleContextError.dependencyTypeMismatch
        }

        return try providerMaps.compactMap { try $0.getOptional() }
    }

    /// Returns a the requested configuration fragment if available on the configuration, or nil otherwise.
    public func getOptionalFragment<C: LLBConfigurationFragment>(_ configurationType: C.Type = C.self) -> C? {
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
    public func declareArtifact(_ path: String) throws -> LLBArtifact {
        return try self.declareArtifact(path, type: .file)
    }

    /// Declares an output directory artifact from the target. If another artifact was declared with the same path, the
    /// same artifact instance will be returned (i.e. it is free to declare the same artifact path anywhere in the rule
    /// ).
    public func declareDirectoryArtifact(_ path: String) throws -> LLBArtifact {
        return try self.declareArtifact(path, type: .directory)
    }

    private func declareArtifact(_ path: String, type: LLBArtifactType) throws -> LLBArtifact {
        return try queue.sync {
            if let artifact = declaredArtifacts[path] {
                guard artifact.type == type else {
                    throw LLBRuleContextError.invalidRedeclarationOfArtifact(existing: artifact, new: type)
                }
                return artifact
            }

            let artifact: LLBArtifact
            switch type {
            case .directory:
                artifact = LLBArtifact.derivedUninitializedDirectory(shortPath: path, roots: artifactRoots)
            case .file:
                artifact = LLBArtifact.derivedUninitialized(shortPath: path, roots: artifactRoots)
            default:
                fatalError("No paths should lead to here")
            }

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
        inputs: [LLBArtifact],
        chainedInput: LLBArtifact? = nil,
        outputs: [LLBArtifact],
        unconditionalOutputs: [LLBArtifact] = [],
        mnemonic: String = "",
        description: String = "",
        workingDirectory: String? = nil,
        preActions: [LLBPreAction] = [],
        cacheableFailure: Bool = false
    ) throws {
        try registerAction(
            arguments: arguments,
            environment: environment,
            inputs: inputs,
            chainedInput: chainedInput,
            outputs: outputs,
            unconditionalOutputs: unconditionalOutputs,
            mnemonic: mnemonic,
            description: description,
            workingDirectory: workingDirectory,
            preActions: preActions,
            dynamicIdentifier: nil,
            cacheableFailure: cacheableFailure
        )
    }

    /// Registers a dynamic action that takes the specified inputs and produces the specified outputs. Only a single
    /// action can be registered for each output, and each output declared from the rule must have 1 producing action.
    /// It is an error to leave an output artifact without a producing action, or to register more than one action for a
    /// particular output.
    public func registerDynamicAction(
        _ dynamicExecutorType: LLBDynamicActionExecutor.Type,
        arguments: [String],
        environment: [String: String] = [:],
        inputs: [LLBArtifact],
        chainedInput: LLBArtifact? = nil,
        outputs: [LLBArtifact],
        unconditionalOutputs: [LLBArtifact] = [],
        mnemonic: String = "",
        description: String = "",
        workingDirectory: String? = nil,
        preActions: [LLBPreAction] = [],
        cacheableFailure: Bool = false
    ) throws {
        try registerAction(
            arguments: arguments,
            environment: environment,
            inputs: inputs,
            chainedInput: chainedInput,
            outputs: outputs,
            unconditionalOutputs: unconditionalOutputs,
            mnemonic: mnemonic,
            description: description,
            workingDirectory: workingDirectory,
            preActions: preActions,
            dynamicIdentifier: dynamicExecutorType.identifier,
            cacheableFailure: cacheableFailure
        )
    }

    private func registerAction(
        arguments: [String],
        environment: [String: String],
        inputs: [LLBArtifact],
        chainedInput: LLBArtifact? = nil,
        outputs: [LLBArtifact],
        unconditionalOutputs: [LLBArtifact],
        mnemonic: String,
        description: String,
        workingDirectory: String?,
        preActions: [LLBPreAction],
        dynamicIdentifier: LLBDynamicActionIdentifier?,
        cacheableFailure: Bool
    ) throws {
        if let chainedInput = chainedInput, !inputs.contains(chainedInput) {
            throw LLBRuleContextError.chainedInputNotInInputs
        }

        let baseEnvironment = (
            getOptionalFragment(LLBActionConfigurationFragment.self)?.additionalEnvironment ?? []
        ).reduce(into: [:]) { $0[$1.name] = $1.value }

        let completeEnvironment = baseEnvironment.merging(environment) { _, new in new }
        try queue.sync {
            // Check that all outputs for the action are uninitialized, have already been declared (and correspond to
            // the declared one) and that they have not been associated to another action. If this turns out to be too
            // slow, we can store more runtime info and validate after rule evaluation is done.
            for output in outputs + unconditionalOutputs {
                guard output.originType == nil,
                      declaredArtifacts[output.shortPath] == output else {
                    throw LLBRuleContextError.outputAlreadyRegistered
                }
            }

            let actionKey = LLBActionKey.command(
                actionSpec: LLBActionSpec(
                    arguments: arguments,
                    environment: completeEnvironment,
                    workingDirectory: workingDirectory,
                    preActions: preActions.map {
                        let environment = baseEnvironment.merging($0.environment) { _, new in new }
                        return LLBPreActionSpec(
                            arguments: $0.arguments,
                            environment: environment,
                            background: $0.background
                        )
                    }
                ),
                inputs: inputs,
                chainedInput: chainedInput,
                outputs: outputs.map { $0.asActionOutput() },
                unconditionalOutputs: unconditionalOutputs.map { $0.asActionOutput() },
                mnemonic: mnemonic,
                description: description,
                dynamicIdentifier: dynamicIdentifier,
                cacheableFailure: cacheableFailure,
                label: label
            )

            registeredActions.append(actionKey)
            let actionIndex = registeredActions.count - 1

            // Mark each of the outputs with the action and output index they were registered with.
            for (index, output) in outputs.enumerated() {
                output.updateOwner(
                    owner: LLBArtifactOwner(
                        actionsOwner: artifactOwnerID,
                        actionIndex: Int32(actionIndex),
                        outputIndex: Int32(index)
                    )
                )
            }
            for (index, unconditionalOutput) in unconditionalOutputs.enumerated() {
                unconditionalOutput.updateOwner(
                    owner: LLBArtifactOwner(
                        actionsOwner: artifactOwnerID,
                        actionIndex: Int32(actionIndex),
                        unconditionalOutputIndex: Int32(index)
                    )
                )
            }
        }
    }

    /// Registers an action that merges the given artifacts into a single directory artifact.
    public func registerMergeDirectories(
        _ inputs: [(artifact: LLBArtifact, path: String?)],
        chainedInput: LLBArtifact? = nil,
        output: LLBArtifact
    ) throws {
        guard output.type == .directory else {
            // Expected only to merge into a directory, merging into a file is an error.
            throw LLBRuleContextError.mergeDirectoriesIntoFileError
        }
        try queue.sync {
            guard output.originType == nil,
                  declaredArtifacts[output.shortPath] == output else {
                throw LLBRuleContextError.outputAlreadyRegistered
            }

            let actionKey = LLBActionKey.mergeTrees(inputs: inputs, chainedInput: chainedInput)

            registeredActions.append(actionKey)
            let actionIndex = registeredActions.count - 1

            output.updateOwner(
                owner: LLBArtifactOwner(
                    actionsOwner: artifactOwnerID,
                    actionIndex: Int32(actionIndex),
                    outputIndex: 0
                )
            )
        }
    }

    /// Registers a static action that writes the specified contents into the given artifact output.
    public func write(contents: Data, to output: LLBArtifact) throws {
        try queue.sync {
            guard output.originType == nil,
                  declaredArtifacts[output.shortPath] == output,
                  staticWriteActions[output.shortPath] == nil else {
                throw LLBRuleContextError.outputAlreadyRegistered
            }

            staticWriteActions[output.shortPath] = contents
        }
    }

    /// Registers a static action that writes the specified contents into the given artifact output.
    public func write(contents: String, to output: LLBArtifact) throws {
        try write(contents: Data(contents.utf8), to: output)
    }
}

extension LLBLabel {
    /// Returns "root" representation of the label which can be used as a
    /// subpath prefix when laying out contents on disk.
    public var asRoot: String {
        return (self.logicalPathComponents + [self.targetName]).joined(separator: "/")
    }
}
