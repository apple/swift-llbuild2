// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemProtocol

extension RuleEvaluationKey: LLBBuildKey {}
extension RuleEvaluationValue: LLBBuildValue {}

// Convenience initializer.
extension RuleEvaluationKey {
    init(label: Label, configuredTargetID: LLBDataID, configurationKey: ConfigurationKey? = nil) {
        self.label = label
        self.configuredTargetID = configuredTargetID
        self.configurationKey = configurationKey ?? ConfigurationKey()
    }
}

// Convenience initializer.
extension RuleEvaluationValue {
    init(providerMap: LLBProviderMap) {
        self.providerMap = providerMap
    }
}

public enum RuleEvaluationError: Error {
    /// Error thrown when no rule lookup delegate is specified.
    case noRuleLookupDelegate

    /// Error thrown when deserialization of the configured target failed.
    case configuredTargetDeserializationError

    /// Error thrown if no rule was found for evaluating a configured target.
    case ruleNotFound

    /// Error thrown when an artifact was already initialized when it was not expected.
    case artifactAlreadyInitialized

    /// Error thrown when an artifact did not get registered as an output to an action.
    case unassignedOutput(Artifact)
}

final class RuleEvaluationFunction: LLBBuildFunction<RuleEvaluationKey, RuleEvaluationValue> {
    let ruleLookupDelegate: LLBRuleLookupDelegate?

    init(engineContext: LLBBuildEngineContext, ruleLookupDelegate: LLBRuleLookupDelegate?) {
        self.ruleLookupDelegate = ruleLookupDelegate
        super.init(engineContext: engineContext)
    }

    override func evaluate(key: RuleEvaluationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<RuleEvaluationValue> {
        guard let ruleLookupDelegate = ruleLookupDelegate else {
            return fi.group.next().makeFailedFuture(RuleEvaluationError.noRuleLookupDelegate)
        }

        let configurationFuture: LLBFuture<ConfigurationValue> = fi.request(key.configurationKey)

        // Read the ConfiguredTargetValue from the database.
        return engineContext.db.get(key.configuredTargetID).flatMapThrowing { (object: LLBCASObject?) in
            guard let data = object?.data,
                  let configuredTargetValue = try? ConfiguredTargetValue(from: data) else {
                throw RuleEvaluationError.configuredTargetDeserializationError
            }

            // Return the decoded ConfiguredTarget.
            return try configuredTargetValue.configuredTarget()
        }.and(configurationFuture).flatMap { (configuredTarget: ConfiguredTarget, configurationValue: ConfigurationValue) in
            guard let rule = ruleLookupDelegate.rule(for: type(of: configuredTarget)) else {
                return fi.group.next().makeFailedFuture(RuleEvaluationError.ruleNotFound)
            }

            let ruleContext = RuleContext(group: fi.group, label: key.label, configurationValue: configurationValue)

            let providersFuture: LLBFuture<[LLBProvider]>
            do {
                // Evaluate the rule with the configured target.
                providersFuture = try rule.compute(configuredTarget: configuredTarget, ruleContext).flatMap { providers in
                    let actionKeyFutures: [LLBFuture<LLBDataID>]
                    do {
                        // Store the action keys in the CAS
                        actionKeyFutures = try ruleContext.registeredActions.map { actionKey in
                            self.engineContext.db.put(data: try actionKey.encode())
                        }
                    } catch {
                        return fi.group.next().makeFailedFuture(error)
                    }

                    let actionKeysFuture: LLBFuture<Void> = LLBFuture.whenAllSucceed(actionKeyFutures, on: fi.group.next()).flatMapThrowing { actionKeyIDs in
                        // Associate the actionKey dataIDs to the artifacts that they produce.
                        for (path, actionOutputIndex) in ruleContext.artifactActionMap {
                            guard let artifact = ruleContext.declaredArtifacts[path],
                                  artifact.originType == nil else {
                                throw RuleEvaluationError.artifactAlreadyInitialized
                            }

                            let artifactOwner = LLBArtifactOwner(
                                actionID: actionKeyIDs[actionOutputIndex.actionIndex],
                                outputIndex: Int32(actionOutputIndex.outputIndex)
                            )
                            artifact.updateOwner(owner: artifactOwner)
                        }
                    }

                    // Upload the static write contents directly into the CAS and associate the dataIDs to the
                    // artifacts.
                    let staticWritesFutures: [LLBFuture<Void>] = ruleContext.staticWriteActions.map { (path, contents) in
                        self.engineContext.db.put(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(contents))).flatMapThrowing { dataID in
                            guard let artifact = ruleContext.declaredArtifacts[path],
                                  artifact.originType == nil else {
                                throw RuleEvaluationError.artifactAlreadyInitialized
                            }
                            artifact.updateID(dataID: dataID)
                        }
                    }
                    let staticWritesFuture = LLBFuture.whenAllSucceed(staticWritesFutures, on: fi.group.next())

                    return actionKeysFuture.and(staticWritesFuture).map { _ in providers }
                }.flatMapThrowing { (providers: [LLBProvider]) in
                    // Ensure all artifacts have been associated to an action.
                    for artifact in ruleContext.declaredArtifacts.values {
                        guard artifact.originType != nil else {
                            throw RuleEvaluationError.unassignedOutput(artifact)
                        }
                    }

                    return providers
                }
            } catch {
                return fi.group.next().makeFailedFuture(error)
            }

            return providersFuture
        }.flatMapThrowing { (providers: [LLBProvider]) in
            try RuleEvaluationValue(providerMap: LLBProviderMap(providers: providers))
        }
    }
}
