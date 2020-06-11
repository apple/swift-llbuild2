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
            let ruleEvaluationKey = RuleEvaluationKey(
                label: key.configuredTargetKey.label,
                configuredTargetValue: configuredTargetValue,
                configurationKey: key.configuredTargetKey.configurationKey
            )

            // Upload the rule evaluation key to the CAS and get the dataID.
            do {
                let byteBuffer = try ruleEvaluationKey.toBytes()
                return self.engineContext.db.put(data: byteBuffer)
            } catch {
                return fi.group.next().makeFailedFuture(error)
            }
        }.flatMap { dataID in
            return fi.request(RuleEvaluationKeyID(ruleEvaluationKeyID: dataID))
        }.map { (ruleEvaluationValue: RuleEvaluationValue) in
            // Retrieve the RuleEvaluationValue's provider map and return it as the EvaluatedTargetValue.
            return EvaluatedTargetValue(providerMap: ruleEvaluationValue.providerMap)
        }
    }
}
