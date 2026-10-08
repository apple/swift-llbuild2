// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public enum ResourceLifetime: Sendable {
    case idempotent
    case versioned
    case requestOnly
}

public protocol FXResource: Sendable {
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

    private struct Entry: Encodable {
        let key: ResourceKey
        let version: Int
    }

    func encode(to encoder: Encoder) throws {
        // `versionedResources` is keyed by `ResourceKey`, which is neither `String` nor `Int`,
        // so `Dictionary.encode(to:)` serializes it as a flat array of key/value pairs in the
        // dictionary's (randomized, per-process) iteration order. Sort by key first so the
        // resulting hash — and therefore the cache path — is stable across processes.
        let sorted = versionedResources.sorted { $0.key < $1.key }.map { Entry(key: $0.key, version: $0.value) }
        try encoder.fxEncodeHash(of: try sorted.fxEncodeJSON())
    }
}
