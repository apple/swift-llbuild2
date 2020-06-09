// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

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

final class RuleEvaluationFunction: LLBBuildFunction<RuleEvaluationKey, RuleEvaluationValue> {
    override func evaluate(key: RuleEvaluationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<RuleEvaluationValue> {
        // FIXME: Implement rule evaluation and provider infrastructure.
        return fi.group.next().makeSucceededFuture(RuleEvaluationValue(providerMap: LLBProviderMap()))
    }
}

