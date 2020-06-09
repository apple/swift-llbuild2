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
    init(label: Label, configuredTargetID: LLBPBDataID) {
        self.label = label
        self.configuredTargetID = configuredTargetID
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
        
        // Read the ConfiguredTargetValue from the database.
        return engineContext.db.get(LLBDataID(key.configuredTargetID)).flatMapThrowing { (object: LLBCASObject?) in
            guard let data = object?.data,
                  let configuredTargetValue = try? ConfiguredTargetValue(from: data) else {
                throw RuleEvaluationError.configuredTargetDeserializationError
            }
            
            // Return the decoded ConfiguredTarget.
            return try configuredTargetValue.configuredTarget()
        }.flatMapThrowing { (configuredTarget: ConfiguredTarget) in
            guard let rule = ruleLookupDelegate.rule(for: type(of: configuredTarget)) else {
                throw RuleEvaluationError.ruleNotFound
            }
            
            // Evaluate the rule with the configured target.
            return try rule.compute(configuredTarget: configuredTarget)
        }.flatMapThrowing {
            try RuleEvaluationValue(providerMap: LLBProviderMap(providers: $0))
        }
    }
}

