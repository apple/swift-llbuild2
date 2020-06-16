// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import LLBBuildSystemProtocol
import LLBBuildSystemTestHelpers
import LLBUtil

import XCTest

/// Key requesting the addition of some numbers. In order to maximize cacheability, the numbers should be sorted.
struct SumKey: LLBBuildKey, Codable, Hashable {
    static let identifier = String(describing: Self.self)

    let numbers: [Int]

    init(numbers: [Int]) {
        self.numbers = numbers
    }

    init(from bytes: LLBByteBuffer) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(bytes.readableBytesView))
    }

    func toBytes(into buffer: inout LLBByteBuffer) throws {
        let encoded = try JSONEncoder().encode(self)
        buffer.writeBytes(encoded)
    }
}

extension Int: LLBBuildValue {}

/// A build function that sums the numbers specified in the build key.
class SumFunction: LLBBuildFunction<SumKey, Int> {
    override func evaluate(key sumKey: SumKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<Int> {
        return engineContext.group.next().makeSucceededFuture(sumKey.numbers.reduce(0, +))
    }
}

/// A function map supporting different kinds of mathematical expressions.
class MathematicsFunctionMap: LLBBuildFunctionLookupDelegate {
    let functionMap: [LLBBuildKeyIdentifier: LLBFunction]

    init(engineContext: LLBBuildEngineContext) {
        self.functionMap = [
            SumKey.identifier: SumFunction(engineContext: engineContext)
        ]
    }

    func lookupBuildFunction(for identifier: LLBBuildKeyIdentifier) -> LLBFunction? {
        return self.functionMap[identifier]
    }
}

class LLBBuildEngineTests: XCTestCase {
    func testFunctionResolutionFailure() throws {
        let testEngine = LLBTestBuildEngine()

        XCTAssertThrowsError(try testEngine.build(SumKey(numbers: [1, 2, 3])).wait()) { error in
            XCTAssertEqual(error as? LLBBuildEngineError, LLBBuildEngineError.unknownBuildKeyIdentifier("SumKey"))
        }
    }

    func testSimpleMathBuild() throws {
        let testEngineContext = LLBTestBuildEngineContext()
        let testEngine = LLBTestBuildEngine(buildFunctionLookupDelegate: MathematicsFunctionMap(engineContext: testEngineContext))

        let result = try XCTUnwrap(testEngine.build(SumKey(numbers: [1, 2, 3])).wait() as Int)

        XCTAssertEqual(result, 6)
    }
}
