// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSFFutures

public protocol FXEntrypoint: FXKey {
    init(withEntrypointPayload casObject: LLBCASObject) throws
    init(withEntrypointPayload buffer: LLBByteBuffer) throws
}

public class FXRuleset {
    public let name: String
    public let entrypoints: [String : any FXEntrypoint.Type]
    public let actionDependencies: [any FXAction.Type]

    let aggregatedResourceEntitlements: FXSortedSet<ResourceKey>

    public init(name: String, entrypoints: [String: any FXEntrypoint.Type]) {
        self.name = name
        self.entrypoints = entrypoints

        aggregatedResourceEntitlements = FXSortedSet<ResourceKey>(entrypoints.values.map { $0.aggregatedResourceEntitlements }.reduce([], +))

        var actionDeps: [String: any FXAction.Type] = [:]
        for ep in entrypoints.values {
            for ad in ep.aggregatedActionDependencies {
                actionDeps[ad.name] = ad
            }
        }
        actionDependencies = Array(actionDeps.values)
    }

    public func constrainResources(_ resources: [ResourceKey: FXResource]) throws -> [ResourceKey: FXResource] {
        var constrained: [ResourceKey: FXResource] = [:]
        for key in aggregatedResourceEntitlements {
            guard let resource = resources[key] else {
                throw FXError.resourceNotFound(key)
            }
            constrained[key] = resource
        }
        return constrained
    }
}

public protocol FXResourceAuthenticator: Sendable {
    // stub protocol for passing an authenticator object for resource creation
}

public protocol FXRulesetPackage {
    associatedtype Config: Sendable

    static func createRulesets() -> [FXRuleset]
    static func createExternalResources(
        _ config: Config,
        group: LLBFuturesDispatchGroup,
        authenticator: FXResourceAuthenticator
    ) async throws -> [FXResource]
}
