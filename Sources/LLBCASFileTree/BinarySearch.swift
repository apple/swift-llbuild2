// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


extension LLBCASFileTree {

    /// Search the index of a matching element consulting a given comparator.
    public static func binarySearch<C: RandomAccessCollection>(_ elements: C, _ compare: (C.Element) -> Int) -> C.Index? {
        var lo: C.Index = elements.startIndex
        var hi: C.Index = elements.index(before: elements.endIndex)

        while true {
            let distance = elements.distance(from: lo, to: hi)
            guard distance >= 0 else { break }

            // Compute the middle index of this iteration's search range.
            let mid = elements.index(lo, offsetBy: distance/2)
            assert(elements.distance(from: elements.startIndex, to: mid) >= 0)
            assert(elements.distance(from: mid, to: elements.endIndex) > 0)

            // If there is a match, return the result.
            let cmp = compare(elements[mid])
            if cmp == 0 {
                return mid
            }

            // Otherwise, continue to search.
            if cmp < 0 {
                hi = elements.index(before: mid)
            } else {
                lo = elements.index(after: mid)
            }
        }

        // Check exit conditions of the binary search.
        assert(elements.distance(from: elements.startIndex, to: lo) >= 0)
        assert(elements.distance(from: lo, to: elements.endIndex) >= 0)

        return nil
    }

}
