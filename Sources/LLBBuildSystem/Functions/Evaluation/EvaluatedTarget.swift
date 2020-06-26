// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

extension LLBEvaluatedTargetKey: LLBBuildKey {}
extension LLBEvaluatedTargetValue: LLBBuildValue {}

// Convenience initializer.
public extension LLBEvaluatedTargetKey {
    init(configuredTargetKey: LLBConfiguredTargetKey) {
        self.configuredTargetKey = configuredTargetKey
    }
}

// Convenience initializer.
extension LLBEvaluatedTargetValue {
    init(providerMap: LLBProviderMap) {
        self.providerMap = providerMap
    }
}

final class EvaluatedTargetFunction: LLBBuildFunction<LLBEvaluatedTargetKey, LLBEvaluatedTargetValue> {
    override func evaluate(key: LLBEvaluatedTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBEvaluatedTargetValue> {
        return fi.request(key.configuredTargetKey, ctx).flatMap { (configuredTargetValue: LLBConfiguredTargetValue) in
            let ruleEvaluationKey = LLBRuleEvaluationKey(
                label: key.configuredTargetKey.label,
                configuredTargetValue: configuredTargetValue,
                configurationKey: key.configuredTargetKey.configurationKey
            )

            // Upload the rule evaluation key to the CAS and get the dataID.
            do {
                let byteBuffer = try ruleEvaluationKey.toBytes()
                return ctx.db.put(data: byteBuffer, ctx)
            } catch {
                return ctx.group.next().makeFailedFuture(error)
            }
        }.flatMap { dataID in
            return fi.request(LLBRuleEvaluationKeyID(ruleEvaluationKeyID: dataID), ctx)
        }.map { (ruleEvaluationValue: LLBRuleEvaluationValue) in
            // Retrieve the RuleEvaluationValue's provider map and return it as the EvaluatedTargetValue.
            return LLBEvaluatedTargetValue(providerMap: ruleEvaluationValue.providerMap)
        }
    }
}
