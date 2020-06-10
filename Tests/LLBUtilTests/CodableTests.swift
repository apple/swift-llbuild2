// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBUtil
import XCTest

final class CodableTests: XCTestCase {
    func testStringRoundtrip() throws {
        let testStrings = [
            "Hello, world!",
            "👩🏿‍💻 https://www.blackgirlscode.com 👩🏿‍💻",
            "X Æ A-12 was born in 2020",
            "Cuarto de libra, con queso, $850. ¡Yo quiero un cuarto de libra con queso ahora!",
            "猫の額",
            "तुमसे ना हो पायेगा",
            "Руки не доходят!",
        ]

        for testString in testStrings {
            let bytes = try testString.toBytes()
            let decoded = try String(from: bytes)
            XCTAssertEqual(decoded, testString)
        }
    }

    func testIntRoundtrip() throws {
        let testInts: [Int] = [42, -23, 1024, Int.max, Int.min]

        for testInt in testInts {
            let bytes = try testInt.toBytes()
            let decoded = try Int(from: bytes)
            XCTAssertEqual(decoded, testInt)
        }
    }
}
