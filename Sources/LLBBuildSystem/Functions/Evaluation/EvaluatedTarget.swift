// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

extension EvaluatedTargetKey: LLBBuildKey {}
extension EvaluatedTargetValue: LLBBuildValue {}

// Convenience initializer.
public extension EvaluatedTargetKey {
    init(configuredTargetKey: ConfiguredTargetKey) {
        self.configuredTargetKey = configuredTargetKey
    }
}

// Convenience initializer.
extension EvaluatedTargetValue {
    init(providerMap: LLBProviderMap) {
        self.providerMap = providerMap
    }
}

final class EvaluatedTargetFunction: LLBBuildFunction<EvaluatedTargetKey, EvaluatedTargetValue> {
    override func evaluate(key: EvaluatedTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<EvaluatedTargetValue> {
        return fi.request(key.configuredTargetKey).flatMap { (configuredTargetValue: ConfiguredTargetValue) in
            // Request the configured target value and upload it to the CAS.
            do {
                let byteBuffer = try configuredTargetValue.encode()
                return self.engineContext.db.put(data: byteBuffer)
            } catch {
                return fi.group.next().makeFailedFuture(error)
            }
        }.flatMap { (configuredTargetID: LLBDataID) in
            // With the dataID for the configured target value, request the evaluation of the rule for that target.
            let ruleEvaluationKey = RuleEvaluationKey(
                label: key.configuredTargetKey.label,
                configuredTargetID: configuredTargetID
            )
            return fi.request(ruleEvaluationKey)
        }.map { (ruleEvaluationValue: RuleEvaluationValue) in
            // Retrieve the RuleEvaluationValue's provider map and return it as the EvaluatedTargetValue.
            return EvaluatedTargetValue(providerMap: ruleEvaluationValue.providerMap)
        }
    }
}

