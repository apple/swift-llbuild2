// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

/// The LLBBuildFunctionMap contains a map of each type of supported build key to the function that implements the logic
/// for evaluating it.
class LLBBuildFunctionMap {
    private let functionMap: [LLBBuildKeyIdentifier: LLBFunction]

    init(
        configuredTargetDelegate: LLBConfiguredTargetDelegate?,
        ruleLookupDelegate: LLBRuleLookupDelegate?,
        dynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate?
    ) {
        self.functionMap = [
            LLBArtifact.identifier: ArtifactFunction(),

            // Evaluation
            LLBConfiguredTargetKey.identifier: ConfiguredTargetFunction(
                configuredTargetDelegate: configuredTargetDelegate
            ),
            LLBEvaluatedTargetKey.identifier: EvaluatedTargetFunction(),
            LLBRuleEvaluationKeyID.identifier: RuleEvaluationFunction(
                ruleLookupDelegate: ruleLookupDelegate
            ),
            LLBConfigurationKey.identifier: ConfigurationFunction(),

            // Execution
            ActionIDKey.identifier: ActionIDFunction(),
            LLBActionKey.identifier: ActionFunction(),
            LLBActionExecutionKey.identifier: ActionExecutionFunction(
                dynamicActionExecutorDelegate: dynamicActionExecutorDelegate
            ),
        ]
    }

    /// Returns the function that processes keys for the specified identifier if supported, or nil otherwise.
    func get(_ type: LLBBuildKeyIdentifier) -> LLBFunction? {
        return functionMap[type]
    }
}
