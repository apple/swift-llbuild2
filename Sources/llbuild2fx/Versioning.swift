// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public enum ConfigurationKey: Hashable, Comparable, Codable {
    case literal(String)
    case prefix(String)
}

public enum ResourceKey: Hashable, Comparable, Codable {
    case external(String)
}

public protocol FXVersioning {
    static var name: String { get }
    static var version: Int { get }
    static var versionDependencies: [FXVersioning.Type] { get }
    static var configurationKeys: [ConfigurationKey] { get }
    static var resourceEntitlements: [ResourceKey] { get }
}

extension FXKey {
    public static var name: String { String(describing: self) }
    public static var version: Int { 0 }
    public static var versionDependencies: [FXVersioning.Type] {
        [FXVersioning.Type]()
    }
    public static var configurationKeys: [ConfigurationKey] {
        [ConfigurationKey]()
    }
    public static var resourceEntitlements: [ResourceKey] {
        [ResourceKey]()
    }
}

extension FXVersioning {
    public static var configurationKeys: [ConfigurationKey] {
        [ConfigurationKey]()
    }
    public static var resourceEntitlements: [ResourceKey] {
        [ResourceKey]()
    }
}

extension FXVersioning {
    private static func aggregateGraph(_ transform: (FXVersioning.Type) -> [FXVersioning.Type])
        -> [FXVersioning.Type]
    {
        var settled = [ObjectIdentifier: FXVersioning.Type]()
        var frontier: [ObjectIdentifier: FXVersioning.Type] = [ObjectIdentifier(self): self]

        while !frontier.isEmpty {
            settled.merge(frontier) { a, _ in a }

            let nestedFrontierCandidates: [[FXVersioning.Type]] = frontier.values.map(transform)

            let frontierCandidates: [FXVersioning.Type] = nestedFrontierCandidates.flatMap { $0 }

            let unsettled: [FXVersioning.Type] = frontierCandidates.filter {
                settled[ObjectIdentifier($0)] == nil
            }

            let tuples: [(ObjectIdentifier, FXVersioning.Type)] = unsettled.map {
                (ObjectIdentifier($0), $0)
            }

            frontier = Dictionary(tuples) { a, _ in a }
        }

        return Array(settled.values)
    }

    static var aggregatedVersionDependencies: [FXVersioning.Type] {
        aggregateGraph {
            $0.versionDependencies
        }
    }

    static var aggregatedVersion: Int {
        return aggregatedVersionDependencies.map { $0.version }.reduce(0, +)
    }

    public static var aggregatedConfigurationKeys: FXSortedSet<ConfigurationKey> {
        return FXSortedSet<ConfigurationKey>(aggregatedVersionDependencies.map { $0.configurationKeys }.reduce([], +))
    }

    public static var aggregatedResourceEntitlements: FXSortedSet<ResourceKey> {
        return FXSortedSet<ResourceKey>(aggregatedVersionDependencies.map { $0.resourceEntitlements }.reduce([], +))
    }

    public static var cacheKeyPrefix: String {
        [
            "\(name)",
            "\(aggregatedVersion)",
        ].joined(separator: "/")
    }
}
