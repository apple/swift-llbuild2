// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import LLBBuildSystemTestHelpers
import LLBBuildSystemProtocol
import LLBCASFileTree
import TSCBasic
import XCTest

extension Int: ConfiguredTarget {}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: ConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ConfiguredTarget> {
        if key.label.targetName == "notFound" {
            return fi.group.next().makeFailedFuture(ConfiguredTargetError.notFound(key.label))
        }
        return fi.group.next().makeSucceededFuture(1)
    }
}

class ConfiguredTargetTests: XCTestCase {
    func testNoDelegateConfigured() throws {
        try withTemporaryDirectory { tempDir in
            let testEngine = LLBTestBuildEngine()

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:target")
            let configuredTargetKey = ConfiguredTargetKey(rootID: LLBPBDataID(dataID), label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey).wait()) { error in
                guard let configuredTargetError = try? XCTUnwrap(error as? ConfiguredTargetError) else {
                    XCTFail("unexpected error type")
                    return
                }
                guard case .noDelegate = configuredTargetError else {
                    XCTFail("expected noDelegate error but got \(configuredTargetError)")
                    return
                }
            }
        }
    }

    func testConfiguredTargetNotFound() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let testEngine = LLBTestBuildEngine(configuredTargetDelegate: configuredTargetDelegate)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:notFound")
            let configuredTargetKey = ConfiguredTargetKey(rootID: LLBPBDataID(dataID), label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey).wait()) { error in
                guard let configuredTargetError = try? XCTUnwrap(error as? ConfiguredTargetError) else {
                    XCTFail("unexpected error type")
                    return
                }
                guard case let .notFound(notFoundLabel) = configuredTargetError else {
                    XCTFail("expected noDelegate error but got \(configuredTargetError)")
                    return
                }

                XCTAssertEqual(notFoundLabel, label)
            }
        }
    }

    func testConfiguredTarget() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: Int.self)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let testEngine = LLBTestBuildEngine(configuredTargetDelegate: configuredTargetDelegate)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:valid")
            let configuredTargetKey = ConfiguredTargetKey(rootID: LLBPBDataID(dataID), label: label)

            let configuredTargetValue = try testEngine.build(configuredTargetKey, as: ConfiguredTargetValue.self).wait()
            let configuredTarget: Int = try configuredTargetValue.typedConfiguredTarget()
            XCTAssertEqual(configuredTarget, 1)
        }
    }
}
