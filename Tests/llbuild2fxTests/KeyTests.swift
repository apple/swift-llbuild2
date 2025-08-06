// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

final class FXKeyTests: XCTestCase {
    private struct TestValue: FXSingleDataIDValue {
        let dataID: LLBDataID
    }

    func testDataIDKeyEncoding() throws {
        struct TestKey: FXKey {
            let dataID: LLBDataID
            func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<TestValue> {
                ctx.group.next().makeSucceededFuture(TestValue(dataID))
            }
        }

        let sensitive = "0~AA=="
        let key = TestKey(dataID: LLBDataID(string: sensitive)!)

        let encoded = try CommandLineArgsEncoder().encode(key)

        XCTAssertEqual(encoded, ["--dataID=\(sensitive)"])
    }

    func testWrappedKeyEncoding() throws {
        struct TestKey: FXKey {
            let value: TestValue
            func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) -> LLBFuture<TestValue> {
                ctx.group.next().makeSucceededFuture(value)
            }
        }

        let sensitive = "0~AA=="
        let key = TestKey(value: TestValue(LLBDataID(string: sensitive)!))

        let encoded = try CommandLineArgsEncoder().encode(key)

        XCTAssertNotEqual(encoded, ["--value=\(sensitive)"])
        XCTAssertEqual(encoded, ["--value=GtSPSWJwedgG"])
    }
}
