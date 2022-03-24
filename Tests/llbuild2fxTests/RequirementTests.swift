// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import llbuild2fx

final class RequirementTests: XCTestCase {
    func testLocalExecutorCanSatisfyRequirement() throws {
        let executor = FXLocalExecutor()

        XCTAssertTrue(executor.canSatisfy(requirements: FXActionExecutionEnvironment.local))
    }

    func testLocalExecutorFailsToSatisfyProhibition() throws {
        let executor = FXLocalExecutor()
        let requirement = NotPredicate(subpredicate: FXActionExecutionEnvironment.local)

        XCTAssertFalse(executor.canSatisfy(requirements: requirement))
    }
}
