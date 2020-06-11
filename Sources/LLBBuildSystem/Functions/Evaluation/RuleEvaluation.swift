// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemProtocol

extension RuleEvaluationKeyID: LLBBuildKey {}
extension RuleEvaluationKey: LLBSerializable {}
extension RuleEvaluationValue: LLBBuildValue {}

extension RuleEvaluationKeyID {
    init(ruleEvaluationKeyID: LLBDataID) {
        self.ruleEvaluationKeyID = ruleEvaluationKeyID
    }
}

// Convenience initializer.
extension RuleEvaluationKey {
    init(label: Label, configuredTargetValue: ConfiguredTargetValue, configurationKey: ConfigurationKey? = nil) {
        self.label = label
        self.configuredTargetValue = configuredTargetValue
        self.configurationKey = configurationKey ?? ConfigurationKey()
    }
}

// Convenience initializer.
extension RuleEvaluationValue {
    init(actionIDs: [LLBDataID], providerMap: LLBProviderMap) {
        self.actionIds = actionIDs
        self.providerMap = providerMap
    }
}

public enum RuleEvaluationError: Error {
    /// Error thrown when no rule lookup delegate is specified.
    case noRuleLookupDelegate

    /// Error thrown when deserialization of the rule evaluatio key failed.
    case ruleEvaluationKeyDeserializationError

    /// Error thrown if no rule was found for evaluating a configured target.
    case ruleNotFound

    /// Error thrown when an artifact was already initialized when it was not expected.
    case artifactAlreadyInitialized

    /// Error thrown when an artifact did not get registered as an output to an action.
    case unassignedOutput(Artifact)
}

final class RuleEvaluationFunction: LLBBuildFunction<RuleEvaluationKeyID, RuleEvaluationValue> {
    let ruleLookupDelegate: LLBRuleLookupDelegate?

    init(engineContext: LLBBuildEngineContext, ruleLookupDelegate: LLBRuleLookupDelegate?) {
        self.ruleLookupDelegate = ruleLookupDelegate
        super.init(engineContext: engineContext)
    }

    override func evaluate(key: RuleEvaluationKeyID, _ fi: LLBBuildFunctionInterface) -> LLBFuture<RuleEvaluationValue> {
        guard let ruleLookupDelegate = ruleLookupDelegate else {
            return fi.group.next().makeFailedFuture(RuleEvaluationError.noRuleLookupDelegate)
        }

        return engineContext.db.get(key.ruleEvaluationKeyID).flatMapThrowing { (object: LLBCASObject?) -> RuleEvaluationKey in
            guard let data = object?.data,
                  let ruleEvaluationKey = try? RuleEvaluationKey(from: data) else {
                throw RuleEvaluationError.ruleEvaluationKeyDeserializationError
            }

            return ruleEvaluationKey
        }.flatMap { ruleEvaluationKey in


            let configurationFuture: LLBFuture<ConfigurationValue> = fi.request(ruleEvaluationKey.configurationKey)
            return configurationFuture.map { (ruleEvaluationKey, $0) }
        }.flatMap { (ruleEvaluationKey: RuleEvaluationKey, configurationValue: ConfigurationValue) in
            let configuredTarget: ConfiguredTarget
            do {
                configuredTarget = try ruleEvaluationKey.configuredTargetValue.configuredTarget()
            } catch {
                return fi.group.next().makeFailedFuture(error)
            }
            guard let rule = ruleLookupDelegate.rule(for: type(of: configuredTarget)) else {
                return fi.group.next().makeFailedFuture(RuleEvaluationError.ruleNotFound)
            }

            let ruleContext = RuleContext(
                group: fi.group,
                label: ruleEvaluationKey.label,
                configurationValue: configurationValue,
                artifactOwnerID: key.ruleEvaluationKeyID
            )

            let providersFuture: LLBFuture<([LLBDataID], [LLBProvider])>
            do {
                // Evaluate the rule with the configured target.
                providersFuture = try rule.compute(configuredTarget: configuredTarget, ruleContext).flatMap { providers in
                    // Upload the static write contents directly into the CAS and associate the dataIDs to the
                    // artifacts. This needs to happen before we serialize the actions, otherwise we risk actions
                    // serializing artifacts that have not yet been updated to contain origin reference.
                    let staticWritesFutures: [LLBFuture<Void>] = ruleContext.staticWriteActions.map { (path, contents) in
                        self.engineContext.db.put(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(contents))).flatMapThrowing { dataID in
                            guard let artifact = ruleContext.declaredArtifacts[path],
                                  artifact.originType == nil else {
                                throw RuleEvaluationError.artifactAlreadyInitialized
                            }
                            artifact.updateID(dataID: dataID)
                        }
                    }
                    let actionKeysFuture: LLBFuture<[LLBDataID]> = LLBFuture.whenAllSucceed(staticWritesFutures, on: fi.group.next()).flatMapThrowing { _ in
                        // Ensure all artifacts have been updated to contain an origin reference, before the actions
                        // are serialized but after static writes have been uploaded.
                        for artifact in ruleContext.declaredArtifacts.values {
                            guard artifact.originType != nil else {
                                throw RuleEvaluationError.unassignedOutput(artifact)
                            }
                        }
                    }.flatMap { _ in
                        let actionKeyFutures: [LLBFuture<LLBDataID>]
                        do {
                            // Store the action keys in the CAS
                            actionKeyFutures = try ruleContext.registeredActions.map { actionKey in
                                self.engineContext.db.put(data: try actionKey.toBytes())
                            }
                        } catch {
                            return fi.group.next().makeFailedFuture(error)
                        }

                        return LLBFuture.whenAllSucceed(actionKeyFutures, on: fi.group.next())
                    }

                    return actionKeysFuture.flatMapThrowing { actionIDs in
                        return (actionIDs, providers)
                    }
                }
            } catch {
                return fi.group.next().makeFailedFuture(error)
            }

            return providersFuture
        }.flatMapThrowing { (actionIDs: [LLBDataID], providers: [LLBProvider]) in
            try RuleEvaluationValue(actionIDs: actionIDs, providerMap: LLBProviderMap(providers: providers))
        }
    }
}
