// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import TSCUtility

public struct FXBuildEngineStatsSnapshot {
    public let currentKeys: [String: Int]
    public let totalKeys: [String: Int]
    public let currentActions: [String: Int]
    public let totalActions: [String: Int]
}

public final class FXBuildEngineStats {
    private let lock = Lock()

    private var currentKeyCounts: [String: Int] = [:]
    private var totalKeyCounts: [String: Int] = [:]
    private var currentActionCounts: [String: Int] = [:]
    private var totalActionCounts: [String: Int] = [:]

    public init() {}

    public var snapshot: FXBuildEngineStatsSnapshot {
        lock.withLock {
            FXBuildEngineStatsSnapshot(
                currentKeys: currentKeyCounts.filter { $0.1 > 0 },
                totalKeys: totalKeyCounts.filter { $0.1 > 0 },
                currentActions: currentActionCounts.filter { $0.1 > 0 },
                totalActions: totalActionCounts.filter { $0.1 > 0 }
            )
        }
    }

    func add(key: String) {
        lock.withLock {
            currentKeyCounts[key] = (currentKeyCounts[key] ?? 0) + 1
            totalKeyCounts[key] = (totalKeyCounts[key] ?? 0) + 1
        }
    }

    func remove(key: String) {
        lock.withLock {
            currentKeyCounts[key] = currentKeyCounts[key]! - 1
        }
    }

    func add(action: String) {
        lock.withLock {
            currentActionCounts[action] = (currentActionCounts[action] ?? 0) + 1
            totalActionCounts[action] = (totalActionCounts[action] ?? 0) + 1
        }
    }

    func remove(action: String) {
        lock.withLock {
            currentActionCounts[action] = currentActionCounts[action]! - 1
        }
    }
}

extension Context {
    var fxBuildEngineStats: FXBuildEngineStats! {
        get {
            guard let stats = self[ObjectIdentifier(FXBuildEngineStats.self)] as? FXBuildEngineStats else {
                return nil
            }

            return stats
        }
        set {
            self[ObjectIdentifier(FXBuildEngineStats.self)] = newValue
        }
    }
}
