// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBBuildSystem
import XCTest

class LabelTests: XCTestCase {
    func testValidLabels() throws {
        let testLabels = [
            "//path": "//path:path",
            "//path/target": "//path/target:target",
            "//path-with-dash": "//path-with-dash:path-with-dash",
            "//path:target-with-dash": "//path:target-with-dash",
            "//path:target": "//path:target",
            "//pa.th:target": "//pa.th:target",
            "//path:tar.get": "//path:tar.get",
            "//:target": "//:target",
        ]

        for (label, expected) in testLabels {
            XCTAssertEqual(try Label(label).canonical, expected)
        }
    }

    func testInvalidLabels() throws {
        let invalidLabels = [
            "://path/label",
            "/path/label",
            "path/label",
            "//",
            "//:",
            "//path:path:path",
            "//path#stuff",
            "//p%a$t^h:target",
            "//path:t@a#rg^et",
            "path:target",
            "",
            "///path",
            "//path/label:target/target",
        ]

        for label in invalidLabels {
            XCTAssertThrowsError(try Label(label))
        }
    }
}
