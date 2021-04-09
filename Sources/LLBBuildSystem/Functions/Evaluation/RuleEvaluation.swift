// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

extension LLBRuleEvaluationKeyID: LLBBuildKey {}
extension LLBRuleEvaluationKey: LLBSerializable {}
extension LLBRuleEvaluationValue: LLBBuildValue {}

extension LLBRuleEvaluationKeyID {
    public init(ruleEvaluationKeyID: LLBDataID) {
        self.ruleEvaluationKeyID = ruleEvaluationKeyID
    }
}

// Convenience initializer.
extension LLBRuleEvaluationKey {
    public init(label: LLBLabel, configuredTargetValue: LLBConfiguredTargetValue, configurationKey: LLBConfigurationKey? = nil) {
        self.label = label
        self.configuredTargetValue = configuredTargetValue
        self.configurationKey = configurationKey ?? LLBConfigurationKey()
    }
}

// Convenience initializer.
extension LLBRuleEvaluationValue {
    public init(actionIDs: [LLBDataID], providerMap: LLBProviderMap) {
        self.actionIds = actionIDs
        self.providerMap = providerMap
    }
}

public enum LLBRuleEvaluationError: Error {
    /// Error thrown when no rule lookup delegate is specified.
    case noRuleLookupDelegate

    /// Error thrown when deserialization of the rule evaluatio key failed.
    case ruleEvaluationKeyDeserializationError

    /// Error thrown if no rule was found for evaluating a configured target.
    case ruleNotFound

    /// Error thrown when an artifact was already initialized when it was not expected.
    case artifactAlreadyInitialized

    /// Error thrown when an artifact did not get registered as an output to an action.
    case unassignedOutput(LLBArtifact)

    /// Error thrown when the rule evaluation was not successful.
    case ruleEvaluationError(LLBLabel, Error)
}

extension LLBRuleEvaluationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .artifactAlreadyInitialized:
            return "artifactAlreadyInitialized"
        case .noRuleLookupDelegate:
            return "noRuleLookupDelegate"
        case .ruleEvaluationError(let label, let error):
            return "ruleEvaluationError(\(label.canonical), \(error))"
        case .ruleEvaluationKeyDeserializationError:
            return "ruleEvaluationKeyDeserializationError"
        case .ruleNotFound:
            return "ruleNotFound"
        case .unassignedOutput(let artifact):
            return "unassignedOutput(\(artifact.path)"
        }
    }
}

public final class RuleEvaluationFunction: LLBBuildFunction<LLBRuleEvaluationKeyID, LLBRuleEvaluationValue> {
    let ruleLookupDelegate: LLBRuleLookupDelegate?

    public init(ruleLookupDelegate: LLBRuleLookupDelegate?) {
        self.ruleLookupDelegate = ruleLookupDelegate
    }

    public override func evaluate(key: LLBRuleEvaluationKeyID, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBRuleEvaluationValue> {
        guard let ruleLookupDelegate = ruleLookupDelegate else {
            return ctx.group.next().makeFailedFuture(LLBRuleEvaluationError.noRuleLookupDelegate)
        }

        return ctx.db.get(key.ruleEvaluationKeyID, ctx).flatMapThrowing { (object: LLBCASObject?) -> LLBRuleEvaluationKey in
            guard let data = object?.data,
                  let ruleEvaluationKey = try? LLBRuleEvaluationKey(from: data) else {
                throw LLBRuleEvaluationError.ruleEvaluationKeyDeserializationError
            }

            ctx.buildEventDelegate?.targetEvaluationRequested(label: ruleEvaluationKey.label)

            return ruleEvaluationKey
        }.flatMap { ruleEvaluationKey in
            let configurationFuture: LLBFuture<LLBConfigurationValue> = fi.request(ruleEvaluationKey.configurationKey, ctx)
            return configurationFuture.map { (ruleEvaluationKey, $0) }
        }.flatMap { (ruleEvaluationKey: LLBRuleEvaluationKey, configurationValue: LLBConfigurationValue) in
            let configuredTarget: LLBConfiguredTarget
            do {
                configuredTarget = try ruleEvaluationKey.configuredTargetValue.configuredTarget(registry: fi.registry)
            } catch {
                return ctx.group.next().makeFailedFuture(error)
            }
            guard let rule = ruleLookupDelegate.rule(for: type(of: configuredTarget)) else {
                return ctx.group.next().makeFailedFuture(LLBRuleEvaluationError.ruleNotFound)
            }

            let ruleContext = LLBRuleContext(
                ctx: ctx,
                label: ruleEvaluationKey.label,
                configurationValue: configurationValue,
                artifactOwnerID: key.ruleEvaluationKeyID,
                targetDependencies: ruleEvaluationKey.configuredTargetValue.targetDependencies,
                fi: fi
            )

            let providersFuture: LLBFuture<([LLBDataID], [LLBProvider])>
            do {
                // Evaluate the rule with the configured target.
                providersFuture = try rule.compute(
                    configuredTarget: configuredTarget,
                    ruleContext
                ).flatMapErrorThrowing { error in
                    throw LLBRuleEvaluationError.ruleEvaluationError(ruleEvaluationKey.label, error)
                }.flatMap { providers in
                    // Upload the static write contents directly into the CAS and associate the dataIDs to the
                    // artifacts. This needs to happen before we serialize the actions, otherwise we risk actions
                    // serializing artifacts that have not yet been updated to contain origin reference.
                    let staticWritesFutures: [LLBFuture<Void>] = ruleContext.staticWriteActions.map { (path, contents) in
                        ctx.db.put(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(contents)), ctx).flatMapThrowing { dataID in
                            guard let artifact = ruleContext.declaredArtifacts[path],
                                  artifact.originType == nil else {
                                throw LLBRuleEvaluationError.artifactAlreadyInitialized
                            }
                            artifact.updateID(dataID: dataID)
                        }
                    }
                    let actionKeysFuture: LLBFuture<[LLBDataID]> = LLBFuture.whenAllSucceed(staticWritesFutures, on: ctx.group.next()).flatMapThrowing { _ in
                        // Ensure all artifacts have been updated to contain an origin reference, before the actions
                        // are serialized but after static writes have been uploaded.
                        for artifact in ruleContext.declaredArtifacts.values {
                            guard artifact.originType != nil else {
                                throw LLBRuleEvaluationError.unassignedOutput(artifact)
                            }
                        }
                    }.flatMap { _ in
                        let actionKeyFutures: [LLBFuture<LLBDataID>]
                        do {
                            // Store the action keys in the CAS
                            actionKeyFutures = try ruleContext.registeredActions.map { actionKey in
                                ctx.db.put(data: try actionKey.toBytes(), ctx)
                            }
                        } catch {
                            return ctx.group.next().makeFailedFuture(error)
                        }

                        return LLBFuture.whenAllSucceed(actionKeyFutures, on: ctx.group.next())
                    }

                    return actionKeysFuture.flatMapThrowing { actionIDs in
                        return (actionIDs, providers)
                    }
                }
            } catch {
                return ctx.group.next().makeFailedFuture(
                    LLBRuleEvaluationError.ruleEvaluationError(ruleEvaluationKey.label,error)
                )
            }

            return providersFuture.map { providers in
                ctx.buildEventDelegate?.targetEvaluationCompleted(label: ruleEvaluationKey.label)
                return providers
            }
        }.flatMapThrowing { (actionIDs: [LLBDataID], providers: [LLBProvider]) in
            try LLBRuleEvaluationValue(actionIDs: actionIDs, providerMap: LLBProviderMap(providers: providers))
        }
    }
}
