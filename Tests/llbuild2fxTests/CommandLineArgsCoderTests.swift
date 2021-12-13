// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

class CommandLineArgsCoderTests: XCTestCase {

    enum Error: Swift.Error {
        case someError
    }

    struct SubA: Codable, Equatable {
        var x: String
        var y: UInt
    }
    struct A: Codable, Equatable {
        var a: String
        var b: String?
        var c: Int?
        var d: [Double]
        var e: SubA
        var f: [String: String]
    }
    struct B: Codable, Equatable {
        var a: Bool
    }

    // CommandLineArgsCoder tests
    func testCommandLineArgsEncoder() throws {
        let a = A(
            a: "abc", b: nil, c: 12, d: [2.3, Double.infinity, -Double.zero, 0.112],
            e: SubA(x: "hello world", y: 12345), f: ["one": "two", "three": "four"])
        let e = CommandLineArgsEncoder()
        XCTAssertNoThrow(try e.encode(a))
        let aE = try e.encode(a)
        XCTAssertEqual(
            aE,
            [
                "--a=abc", "--c=12", "--d.0=2.3", "--d.1=inf", "--d.2=-0.0", "--d.3=0.112", "--e.x=hello world",
                "--e.y=12345", "--f.one=two", "--f.three=four",
            ])
    }

    func testCommandLineArgsDecoder() throws {
        let str = [
            "--a=abc", "--c=12", "--d.0=2.3", "--d.1=inf", "--d.2=-0.0", "--d.3=0.112", "--e.x=hello world",
            "--e.y=12345", "--f.one=two", "--f.three=four",
        ]
        let d = CommandLineArgsDecoder()
        XCTAssertNoThrow(try d.decode(from: str) as A)
        let aD: A = try d.decode(from: str)
        XCTAssertEqual(
            aD,
            A(
                a: "abc", b: nil, c: 12, d: [2.3, Double.infinity, -Double.zero, 0.112],
                e: SubA(x: "hello world", y: 12345), f: ["one": "two", "three": "four"]))
    }

    func testCommandLineArgsTypeRoundTrip() throws {
        let a = A(
            a: "abc", b: nil, c: 12, d: [2.3, Double.infinity, -Double.zero, 0.112],
            e: SubA(x: "hello world", y: 12345), f: ["one": "two", "three": "four"])
        let e = CommandLineArgsEncoder()
        let d = CommandLineArgsDecoder()
        XCTAssertNoThrow(try e.encode(a))
        let aE = try e.encode(a)
        XCTAssertNoThrow(try d.decode(from: aE) as A)
        let aD: A = try d.decode(from: aE)
        XCTAssertEqual(a, aD)
    }

    func testCommandLineArgsArgsRoundTrip() throws {
        let str = [
            "--a=abc", "--c=12", "--d.0=2.3", "--d.1=inf", "--d.2=-0.0", "--d.3=0.112", "--e.x=hello world",
            "--e.y=12345", "--f.one=two", "--f.three=four",
        ]
        let d = CommandLineArgsDecoder()
        let e = CommandLineArgsEncoder()
        XCTAssertNoThrow(try d.decode(from: str) as A)
        let aD: A = try d.decode(from: str)
        XCTAssertNoThrow(try e.encode(aD))
        let aE = try e.encode(aD)
        XCTAssertEqual(aE, str)
    }

    func testCommandLineArgsFlexibleDecoder() throws {
        let str = [
            "--a", "abc", "--c=12", "--d", "2.3", "--d", "inf", "--d", "-0.0", "--d", "0.112", "--e.x=hello world",
            "--e.y=12345", "--f.one", "two", "--f.three", "four",
        ]
        let d = CommandLineArgsDecoder()
        XCTAssertNoThrow(try d.decode(from: str) as A)
        let aD: A = try d.decode(from: str)
        XCTAssertEqual(
            aD,
            A(
                a: "abc", b: nil, c: 12, d: [2.3, Double.infinity, -Double.zero, 0.112],
                e: SubA(x: "hello world", y: 12345), f: ["one": "two", "three": "four"]))
        let str2 = ["--a"]
        XCTAssertNoThrow(try d.decode(from: str2) as B)
        let bD: B = try d.decode(from: str2)
        XCTAssertEqual(bD, B(a: true))
    }

}
