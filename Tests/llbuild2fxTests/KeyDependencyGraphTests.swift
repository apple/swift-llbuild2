// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

extension Int: @retroactive FXRequestKey {
    public var stableHashValue: LLBDataID {
        var v = self
        let s: Int = MemoryLayout<Int>.size
        return withUnsafePointer(to: &v) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: s) { pb in
                LLBDataID(directHash: Array(UnsafeBufferPointer(start: pb, count: s)))
            }
        }
    }
}

final class KeyDependencyGraphTests: XCTestCase {
    func testSimpleCycle() throws {
        let keyDependencyGraph = FXKeyDependencyGraph()

        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 1, to: 2))
        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 2, to: 3))
        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 3, to: 4))

        XCTAssertThrowsError(try keyDependencyGraph.addEdge(from: 4, to: 1)) { error in
            guard case FXError.cycleDetected(let cycle) = error else {
                XCTFail("Unexpected error type")
                return
            }

            XCTAssertEqual([4, 1, 2, 3, 4], cycle as! [Int])
        }
    }
}
