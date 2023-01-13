// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import NIOCore

/// An enum representing the available types of dependencies.
public enum LLBTargetDependency {
    /// Represents a dependency on a single target.
    case single(LLBLabel, LLBConfigurationKey?)
    
    /// Represents a list of dependency targets. All of the labels will be evaluated using the same configuration key.
    /// Note: the configuration could be represented instead as a diff or patch to apply to the current configuration,
    /// might allow an easier representation for the changes required for the dependency configuration.
    case list([LLBLabel], LLBConfigurationKey?)
    
    /// Convenience initializer for the single dependency with no configuration
    static public func single(_ label: LLBLabel) -> Self {
        return .single(label, nil)
    }
    
    /// Convenience initializer for the list dependency with no configuration.
    static public func list(_ labels: [LLBLabel]) -> Self {
        return .list(labels, nil)
    }
}

/// Protocol that configured target instances must conform to.
public protocol LLBConfiguredTarget: LLBPolymorphicSerializable {
 
    /// Returns a dictionary of dependencies, where the keys corresponds to client-domain identifiers that can be used
    /// to retrieve the dependencies from the rule context. The values correspond to the description of the target or
    /// targets dependencies, including the label and an optional configuration key to use when evaluating the target.
    /// If the configuration key is nil for a particular LLBTargetDependency case, the dependency will use the same
    /// configuration as this configured target.
    var targetDependencies: [String: LLBTargetDependency] { get }
}

public extension LLBConfiguredTarget {
    static var identifier: String {
        return self.polymorphicIdentifier
    }
}

/// Protocol definition for a delegate that provides an LLBFuture<ConfiguredTarget> instance.
public protocol LLBConfiguredTargetDelegate {

    /// Returns a future with a ConfiguredTarget for the given ConfiguredTargetKey. This method will be invoked inside
    /// of a ConfiguredTargetFunction evaluation, so the invocation of this method will only happen once per
    /// ConfiguredTargetKey. There is no need to implement additional caching inside of the delegate method.
    /// The LLBBuildFunctionInterface is also provided to allow requesting additional keys during evaluation. Any custom
    /// function that is needed to evaluate a ConfiguredTarget will need to be implemented by the client and returned
    /// through the LLBBuildFunctionLookupDelegate implementation.
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) throws -> LLBFuture<LLBConfiguredTarget>
}
