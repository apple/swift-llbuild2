// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

final class EqualityPredicateTests: XCTestCase {
    func testTrueTrue() {
        let lhs = ConstantExpression<Any?, Bool>(value: true)
        let rhs = ConstantExpression<Any?, Bool>(value: true)

        let predicate = EqualityPredicate(leftExpression: lhs, rightExpression: rhs)

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testTrueFalse() {
        let lhs = ConstantExpression<Any?, Bool>(value: true)
        let rhs = ConstantExpression<Any?, Bool>(value: false)

        let predicate = EqualityPredicate(leftExpression: lhs, rightExpression: rhs)

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalseTrue() {
        let lhs = ConstantExpression<Any?, Bool>(value: false)
        let rhs = ConstantExpression<Any?, Bool>(value: true)

        let predicate = EqualityPredicate(leftExpression: lhs, rightExpression: rhs)

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalseFalse() {
        let lhs = ConstantExpression<Any?, Bool>(value: false)
        let rhs = ConstantExpression<Any?, Bool>(value: false)

        let predicate = EqualityPredicate(leftExpression: lhs, rightExpression: rhs)

        XCTAssertTrue(predicate.evaluate(with: nil))
    }
}

final class ContantPredicateTests: XCTestCase {
    func testTrue() {
        let predicate = ConstantPredicate<Any?>(value: true)

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testFalse() {
        let predicate = ConstantPredicate<Any?>(value: false)

        XCTAssertFalse(predicate.evaluate(with: nil))
    }
}

final class NotPredicateTests {
    func testTrue() {
        let predicate = NotPredicate(subpredicate: ConstantPredicate<Any?>(value: true))

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalse() {
        let predicate = NotPredicate(subpredicate: ConstantPredicate<Any?>(value: false))

        XCTAssertTrue(predicate.evaluate(with: nil))
    }
}

final class AndPredicateTests: XCTestCase {
    func testEmpty() {
        let predicate = AndPredicate<Any?>(subpredicates: [])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testTrue() {
        let predicate = AndPredicate(subpredicates: [AnyPredicate(ConstantPredicate<Any?>(value: true))])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testTrueTrue() {
        let predicate = AndPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
        ])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testFalse() {
        let predicate = AndPredicate(subpredicates: [AnyPredicate(ConstantPredicate<Any?>(value: false))])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testTrueFalse() {
        let predicate = AndPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
        ])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalseTrue() {
        let predicate = AndPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
        ])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalseFalse() {
        let predicate = AndPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
        ])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }
}

final class OrPredicateTests: XCTestCase {
    func testEmpty() {
        let predicate = OrPredicate<Any?>(subpredicates: [])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testTrue() {
        let predicate = OrPredicate(subpredicates: [AnyPredicate(ConstantPredicate<Any?>(value: true))])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testTrueTrue() {
        let predicate = OrPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
        ])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testTrueFalse() {
        let predicate = OrPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
        ])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testFalseTrue() {
        let predicate = OrPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
            AnyPredicate(ConstantPredicate<Any?>(value: true)),
        ])

        XCTAssertTrue(predicate.evaluate(with: nil))
    }

    func testFalseFalse() {
        let predicate = OrPredicate(subpredicates: [
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
            AnyPredicate(ConstantPredicate<Any?>(value: false)),
        ])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }

    func testFalse() {
        let predicate = OrPredicate(subpredicates: [AnyPredicate(ConstantPredicate<Any?>(value: false))])

        XCTAssertFalse(predicate.evaluate(with: nil))
    }
}
