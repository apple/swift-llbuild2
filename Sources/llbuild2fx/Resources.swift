// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public enum ResourceLifetime {
    case idempotent
    case versioned
    case requestOnly
}

public protocol FXResource {
    var name: String { get }
    var version: Int? { get }
    var lifetime: ResourceLifetime { get }
}



final class ResourceVersions<K: FXVersioning>: Encodable {
    private let versionedResources: [ResourceKey: Int]

    init(resources: [ResourceKey: FXResource]) {
        var versionedResources: [ResourceKey: Int] = [:]
        for key in K.resourceEntitlements {
            if let res = resources[key], case .versioned = res.lifetime, let version = res.version {
                versionedResources[key] = version
            }
        }
        self.versionedResources = versionedResources
    }

    func isNoop() -> Bool {
        return versionedResources.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        try encoder.fxEncodeHash(of: versionedResources.fxEncodeJSON())
    }
}
