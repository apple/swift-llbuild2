// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

private struct TestableValue {
    let value: Bool
}

final class ExpressionTests: XCTestCase {
    func testConstantExpression() {
        let expr = ConstantExpression<Any?, Bool>(value: true)

        let value = expr.value(with: nil)

        XCTAssertEqual(value, true)
    }

    func testKeyPathExpression() {
        let obj = TestableValue(value: true)
        let expr = KeyPathExpression(keyPath: \TestableValue.value)

        let value = expr.value(with: obj)

        XCTAssertEqual(value, true)
    }
}
