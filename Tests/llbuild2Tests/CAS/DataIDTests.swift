// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import llbuild2


class LLBDataIDTests: XCTestCase {

    /// Check that DataID is codable, and that it uses a flat representation.
    func testCodability() throws {
        // We have to wrap in an array, as Foundation doesn't allow top-level scalar items.
        let id = LLBDataID(directHash: Array("abc def".utf8))
        let json = try JSONEncoder().encode([id])
        XCTAssertEqual(String(decoding: json, as: Unicode.UTF8.self), "[\"0~YWJjIGRlZg==\"]")
        XCTAssertEqual(try JSONDecoder().decode([LLBDataID].self, from: json), [id])

        // Check that invalid JSON is detected.
        XCTAssertThrowsError(try JSONDecoder().decode([LLBDataID].self, from: Data("[\"not hex\"]".utf8)))
    }
}

