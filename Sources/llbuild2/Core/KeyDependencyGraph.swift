// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers

public enum LLBKeyDependencyGraphError: Error {
    case cycleDetected([LLBKey])
}

/// Key -> Key dependency graph maintainer. Currently used for cycle detection during the request of keys.
public class LLBKeyDependencyGraph {
    // Use Ints containing the hashValue values for each key. They should be stable during the execution of this
    // process, and we're not storing them for usage in future process invocations. If that changes, this should
    // probably be refactored.
    private var edges: [Int: Set<Int>]

    // A map of the hashValue to the key. This allows us to preserve key information if paths are founds, so that
    // they can be useful when debugging.
    private var knownKeys: [Int: LLBKey]

    private struct ActiveEdge: Hashable {
        let originID: Int
        let destinationID: Int
    }

    /// Keeps track of the active edges. The value is the count of how many times the edge has been recorded.
    /// An active edge is one where its future is not completed yet.
    private var activeEdges: [ActiveEdge: Int] = [:]

    private let lock = Lock()

    public init() {
        self.edges = [:]
        self.knownKeys = [:]
    }

    /// Attempts to add a detected dependency edge to the graph, but throws if a cycle is detected.
    public func addEdge(from origin: LLBKey, to destination: LLBKey) throws {
        // This is the biggest expense in this method. We need to find a way to identify keys in a faster way than
        // serializing and hashing.
        let originID = origin.hashValue
        let destinationID = destination.hashValue

        // Check if the direct dependency is already known, in which case, skip the check since the edge is already
        // been proven to not have a cycle.
        lock.lock()
        activeEdges[ActiveEdge(originID: originID, destinationID: destinationID), default: 0] += 1
        if self.edges[originID]?.contains(destinationID) == true {
            defer { lock.unlock() }
            return
        }
        lock.unlock()

        // Populate the knownKeys store with the new edge nodes, in case it doesn't exist.
        lock.lock()
        if self.knownKeys[originID] == nil {
            self.knownKeys[originID] = origin
        }
        if self.knownKeys[destinationID] == nil {
            self.knownKeys[destinationID] = destination
        }
        lock.unlock()

        // Check if there's a path from the destination to the origin, as that would be a clear indication that adding
        // the edge from the origin to the destination would introduce a cycle. This works because the graph starts
        // by definition without cycles, so cycles can only be introduced if a new edge would create it. The edges are
        // updated within the same lock to avoid a race condition where 2 threads might add edges that would conflict.
        lock.lock()
        if let path = anyPath(from: destinationID, to: originID) {
            let keyPath = path.map { self.knownKeys[$0]! }
            lock.unlock()
            throw LLBKeyDependencyGraphError.cycleDetected([origin] + keyPath)
        }

        var destinations = self.edges[originID, default: Set()]
        destinations.insert(destinationID)
        self.edges[originID] = destinations
        lock.unlock()
    }

    public func removeEdge(from origin: LLBKey, to destination: LLBKey) {
        let originID = origin.hashValue
        let destinationID = destination.hashValue
        let actEdge = ActiveEdge(originID: originID, destinationID: destinationID)

        lock.lock()
        var num = activeEdges[actEdge]!
        precondition(num > 0)
        num -= 1
        if num == 0 {
            activeEdges.removeValue(forKey: actEdge)
            var destinations = self.edges[originID]!
            destinations.remove(destinationID)
            if destinations.isEmpty {
                self.edges.removeValue(forKey: originID)
            } else {
                self.edges[originID] = destinations
            }
        } else {
            activeEdges[actEdge] = num
        }
        lock.unlock()
    }

    /// Simple mechanism to find a path between 2 nodes. It doesn't care if its the shortest path, only whether a path
    /// exists. If a path is found, it returns it.
    /// Must be called inside the lock.
    private func anyPath(from origin: Int, to destination: Int) -> [Int]? {
        // If the origin is the destination, then the path is itself.
        if origin == destination {
            return [origin]
        }

        // Keeps track of the path between the nodes as it searches through.
        var path = [Int]()

        // Stack with the unprocessed nodes.
        var stack = [Int?]()

        // Set of visited nodes to skip if found again.
        var visited = Set<Int>()

        stack.append(origin)

        // While there are nodes to process, keep on going.
        while !stack.isEmpty {
            // If we find a sentinel, pop the last path node from the stack.
            guard let current = stack.removeLast() else {
                path.removeLast()
                continue
            }

            // If we have seen the node before, skip it, since it means that we didn't find a path through that node.
            if visited.contains(current) {
                continue
            } else {
                visited.insert(current)
            }

            // If the current key does not have dependencies, skip it.
            guard let dependencies = self.edges[current] else {
                continue
            }

            // Add the current node to the path stack.
            path.append(current)

            if dependencies.contains(destination) {
                return path + [destination]
            } else {
                // Insert nil sentinel that signals where the current path ends, to pop it from the path stack.
                stack.append(nil)

                // Add the dependencies to scan.
                stack.append(contentsOf: dependencies)
            }
        }

        return nil
    }
}
