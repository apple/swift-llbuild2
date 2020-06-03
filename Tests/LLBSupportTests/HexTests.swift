// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import LLBSupport

class HexTests: XCTestCase {
    func testHexDecode() {
        XCTAssert("0".llbHexDecode() == nil)
        XCTAssert("0x".llbHexDecode() == nil)
        XCTAssertEqual("00".llbHexDecode()!, [0])
        XCTAssertEqual("01".llbHexDecode()!, [1])
        XCTAssertEqual("0a".llbHexDecode()!, [10])
        XCTAssertEqual("10".llbHexDecode()!, [16])
        XCTAssertEqual("a0".llbHexDecode()!, [160])
    }

    func testHexEncode() {
        XCTAssertEqual(hexEncode([0]), "00")
        XCTAssertEqual(hexEncode([1]), "01")
        XCTAssertEqual(hexEncode([10]), "0a")
        XCTAssertEqual(hexEncode([16]), "10")
        XCTAssertEqual(hexEncode([160]), "a0")
    }
}
