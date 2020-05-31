// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import llbuild2
import LLBUtil

extension Int: LLBKey {}

final class KeyDependencyGraphTests: XCTestCase {
    func testSimpleCycle() throws {
        let keyDependencyGraph = LLBKeyDependencyGraph()

        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 1, to: 2))
        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 2, to: 3))
        XCTAssertNoThrow(try keyDependencyGraph.addEdge(from: 3, to: 4))

        XCTAssertThrowsError(try keyDependencyGraph.addEdge(from: 4, to: 1)) { error in
            guard case let LLBKeyDependencyGraphError.cycleDetected(cycle) = error else {
                XCTFail("Unexpected error type")
                return
            }

            XCTAssertEqual([4, 1, 2, 3, 4], cycle as! [Int])
        }
    }
}

