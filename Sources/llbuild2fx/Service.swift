// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import TSFFutures

public class FXService {
    public let group: LLBFuturesDispatchGroup

    public enum Error: Swift.Error {
        case duplicateResource(String)
    }

    private let _resources = NIOLockedValueBox([ResourceKey: FXResource]())
    private let _rulesets = NIOLockedValueBox([String: FXRuleset]())

    public init(group: LLBFuturesDispatchGroup) {
        self.group = group
    }

    public func ruleset(_ name: String) -> FXRuleset? {
        return _rulesets.withLockedValue { $0[name] }
    }

    public func resources(for ruleset: FXRuleset) throws -> [ResourceKey: FXResource] {
        return try _resources.withLockedValue {
            return try ruleset.constrainResources($0)
        }
    }

    public func registerResource(_ resource: FXResource) throws {
        try _resources.withLockedValue { resources in
            guard !resources.keys.contains(.external(resource.name)) else {
                throw Error.duplicateResource(resource.name)
            }
            resources[.external(resource.name)] = resource
        }
    }

    public func registerPackage<T: FXRulesetPackage>(_ pkg: T.Type, with config: T.Config, authenticator: FXResourceAuthenticator) async throws {

        let newResources = try await pkg.createExternalResources(config, group: group, authenticator: authenticator)
        try _resources.withLockedValue { resources in
            // check all resources first, so that we don't leave anything dangling on failure
            for r in newResources {
                if resources.keys.contains(.external(r.name)) {
                    throw Error.duplicateResource(r.name)
                }
            }

            for r in newResources {
                resources[.external(r.name)] = r
            }
        }

        let newRulesets = pkg.createRulesets()
        _rulesets.withLockedValue {
            for ruleset in newRulesets {
                $0[ruleset.name] = ruleset
            }
        }
    }
}
