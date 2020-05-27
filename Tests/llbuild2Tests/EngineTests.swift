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

final class EngineTests: XCTestCase {
    func testBasicMath() {
        let staticIntFunction = LLBSimpleFunction { (fi, key) in
            guard let key = key as? String else {
                fatalError("Expected a String key")
            }

            guard let intValue = Int(key.dropFirst()) else {
                fatalError("Expected a valid number after droppping the first character")
            }

            return fi.group.next().makeSucceededFuture(intValue)
        }

        let sumFunction = LLBSimpleFunction { (fi, key) in
            let v1 = fi.request("v1", as: Int.self)
            let v2 = fi.request("v2", as: Int.self)
            return v1.and(v2).map { r in
                return r.0 + r.1
            }.map { $0 as LLBValue }
        }

        let keyMap: [String: LLBFunction] = [
            "v1": staticIntFunction,
            "v2": staticIntFunction,
            "sum": sumFunction,
        ]

        let delegate = LLBStaticFunctionDelegate(keyMap: keyMap)
        let engine = LLBEngine(delegate: delegate)

        do {
            let s = try engine.build(key: "sum", as: Int.self).wait()
            XCTAssertEqual(s, 3)
        } catch {
            XCTFail("error \(error)")
        }
    }
}

extension Int: LLBValue {}
