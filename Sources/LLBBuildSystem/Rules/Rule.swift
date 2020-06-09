// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

/// Protocol definition for a rule lookup delegate, which looks up the rule definition for a given configured target
/// type.
public protocol LLBRuleLookupDelegate {

    /// Lookup a rule implementation for a given configured target type, or nil if none is known.
    func rule(for configuredTargetType: ConfiguredTarget.Type) -> LLBRule?
}


/// Protocol definition for a rule implementation, that evaluates a configured target and returns a list of providers
/// as the interface for downstream dependents of the target.
public protocol LLBRule {
    /// Computes a configured target and returns a list of providers.
    func compute(configuredTarget: ConfiguredTarget) throws -> [LLBProvider]
}

public enum LLBBuildRuleError: Error {
    case unexpectedType
}

/// "Abstract" implementation of an LLBRule that type casts the configured target to the user declared type.
open class LLBBuildRule<C: ConfiguredTarget>: LLBRule {
    public init() {}
    
    public final func compute(configuredTarget: ConfiguredTarget) throws -> [LLBProvider] {
        guard let typedConfiguredTarget = configuredTarget as? C else {
            throw LLBBuildRuleError.unexpectedType
        }
        
        return evaluate(configuredTarget: typedConfiguredTarget)
    }

    /// Evaluates a configured target to return a list of providers. This method is required to be overridden by
    /// subclasses of LLBBuildRule.
    open func evaluate(configuredTarget: C) -> [LLBProvider] {
        fatalError("This should be overridden by a subclass")
    }
}
