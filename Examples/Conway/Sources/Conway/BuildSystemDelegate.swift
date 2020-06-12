// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBBuildSystem
import LLBBuildSystemProtocol
import llbuild2

enum ConwayConfiguredTargetError: Error {
    case notFound
}

/// Implementation of the LLBBuildEngine delegates for extending the engine with our custom functions, rules and
/// targets.
class ConwayBuildSystemDelegate {
    /// Registry of available rules in the Conway build system. This means that CellTarget targets are evaluated using
    /// the CellRule implementation. Same for the BoardTarget and BoardRule. Rules are used mostly for processing
    /// artifact related computations, since it has access to APIs for managing inputs, outputs and action registration.
    let rules: [String: LLBRule] = [
        CellTarget.identifier: CellRule(),
        BoardTarget.identifier: BoardRule(),
    ]

    /// Registry of key identifiers to the functions that evaluate them. Functions are used to access the raw llbuild2
    /// engine capabilities for implementing generic functional computations that are not necesarily artifact related.
    let functions: [LLBBuildKeyIdentifier: LLBFunction]

    init(engineContext: LLBBuildEngineContext) {
        self.functions = [
            ConwayConfigurationKey.identifier: ConwayConfigurationFunction(engineContext: engineContext),
            GenerationKey.identifier: GenerationFunction(engineContext: engineContext),
        ]
    }
}

extension ConwayBuildSystemDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(
        for key: ConfiguredTargetKey,
        _ fi: LLBBuildFunctionInterface
    ) throws -> LLBFuture<ConfiguredTarget> {
        let label = key.label

        if label.logicalPathComponents[0] == "cell" {
            // Cell targets are identified using the `//cell/<generation>:<x>-<y>` scheme.
            return try CellTarget.with(key: key, fi).map { $0 }
        } else if label.logicalPathComponents[0] == "board" {
            // Board targets are identified using the `//board:<generation>` scheme.
            return try BoardTarget.with(key: key, fi).map { $0 }
        }

        // Only cell and board targets are supported.
        throw ConwayConfiguredTargetError.notFound
    }
}

extension ConwayBuildSystemDelegate: LLBRuleLookupDelegate {
    func rule(for configuredTargetType: ConfiguredTarget.Type) -> LLBRule? {
        return rules[configuredTargetType.identifier]
    }
}

extension ConwayBuildSystemDelegate: LLBBuildFunctionLookupDelegate {
    func lookupBuildFunction(for identifier: LLBBuildKeyIdentifier) -> LLBFunction? {
        return functions[identifier]
    }
}
