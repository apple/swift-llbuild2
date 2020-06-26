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
        let staticIntFunction = LLBSimpleFunction { (fi, key, ctx) in
            guard let key = key as? String else {
                fatalError("Expected a String key")
            }

            guard let intValue = Int(key.dropFirst()) else {
                fatalError("Expected a valid number after droppping the first character")
            }

            return ctx.group.next().makeSucceededFuture(intValue)
        }

        let sumFunction = LLBSimpleFunction { (fi, key, ctx) in
            let v1 = fi.request("v1", as: Int.self, ctx)
            let v2 = fi.request("v2", as: Int.self, ctx)
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
        let ctx = Context()

        do {
            let s = try engine.build(key: "sum", as: Int.self, ctx).wait()
            XCTAssertEqual(s, 3)
        } catch {
            XCTFail("error \(error)")
        }
    }

    func testDependencyCycles() {
        let modFunction = LLBSimpleFunction { (fi, key, ctx) in
            let intKey = Int(key as! String)!
            return fi.request("\((intKey + 1) % 4)", ctx).map { _ in 42 }
        }

        let keyMap: [String: LLBFunction] = [
            "0": modFunction,
            "1": modFunction,
            "2": modFunction,
            "3": modFunction,
        ]

        let delegate = LLBStaticFunctionDelegate(keyMap: keyMap)
        let engine = LLBEngine(delegate: delegate)
        let ctx = Context()

        XCTAssertThrowsError(try engine.build(key: "1", as: Int.self, ctx).wait()) { error in
            guard case let LLBKeyDependencyGraphError.cycleDetected(cycle) = error else {
                XCTFail("Unexpected error type")
                return
            }

            XCTAssertEqual(["0", "1", "2", "3", "0"], cycle as! [String])
        }
    }
}

extension Int: LLBValue {}
