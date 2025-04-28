// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public class FXRuleset {
    public let name: String
    public let entrypoints: [String : FXVersioning.Type]
    let aggregatedResourceEntitlements: FXSortedSet<ResourceKey>

    public init(name: String, entrypoints: [String: FXVersioning.Type]) {
        self.name = name
        self.entrypoints = entrypoints

        aggregatedResourceEntitlements = FXSortedSet<ResourceKey>(entrypoints.values.map { $0.aggregatedResourceEntitlements }.reduce([], +))
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
