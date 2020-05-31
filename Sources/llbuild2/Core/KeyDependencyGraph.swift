// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch

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

    private let queue = DispatchQueue.global(qos: .userInteractive)

    public init() {
        self.edges = [:]
        self.knownKeys = [:]
    }

    /// Attempts to add a detected dependency edge to the graph, but throws if a cycle is detected.
    public func addEdge(from origin: LLBKey, to destination: LLBKey) throws {
        let originID = origin.digest.hashValue
        let destinationID = destination.digest.hashValue

        // Populate the knownKeys store with the new edge nodes, in case it doesn't exist.
        queue.sync {
            if self.knownKeys[originID] == nil {
                self.knownKeys[originID] = origin
            }
            if self.knownKeys[destinationID] == nil {
                self.knownKeys[destinationID] = destination
            }
        }

        // Check if there's a path from the destination to the origin, as that would be a clear indication that adding
        // the edge from the origin to the destination would introduce a cycle. This works because the graph starts
        // by definition without cycles, so cycles can only be introduced if a new edge would create it.
        if let path = anyPath(from: destinationID, to: originID) {
            let keyPath = queue.sync { path.map { self.knownKeys[$0]! } }
            throw LLBKeyDependencyGraphError.cycleDetected([origin] + keyPath)
        }

        // Update the edges using the serial queue to avoid race conditions. The fact that this lock is separate from
        // the lock in anyPath does seem to imply that there could be some race condition where 2 threads might not
        // find cycles independently when run in parallel but would indeed find one if they were done serially. In
        // practice, because of the nature of how edges are added (they are not random, but in fact constructed in
        // dependency order) I _believe_ this should not be a problem. Of course, I could be wrong and someone could
        // find such an edge case in the wild. But until then, not having the locks mixed seems to make sense to me
        // from a performance perspective, to avoid unnecessary delays when processing.
        queue.sync {
            var destinations = self.edges[originID, default: Set()]
            destinations.insert(destinationID)
            self.edges[originID] = destinations
        }
    }

    /// Simple mechanism to find a path between 2 nodes. It doesn't care if its the shortest path, only whether a path
    /// exists. If a path is found, it returns it.
    private func anyPath(from origin: Int, to destination: Int) -> [Int]? {
        // If the origin is the destination, then the path is itself.
        if origin == destination {
            return [origin]
        }

        // Make a thread local copy since this method may be invoked from multiple threads.
        let localEdges = queue.sync { self.edges }

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
            guard let dependencies = localEdges[current] else {
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
