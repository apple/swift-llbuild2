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
import LLBCASFileTree
import TSCBasic
import XCTest

extension Int: LLBConfiguredTarget {}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBConfiguredTarget> {
        if key.label.targetName == "notFound" {
            return fi.group.next().makeFailedFuture(LLBConfiguredTargetError.notFound(key.label))
        }
        return fi.group.next().makeSucceededFuture(1)
    }
}

class ConfiguredTargetTests: XCTestCase {
    func testNoDelegateConfigured() throws {
        try withTemporaryDirectory { tempDir in
            let testEngine = LLBTestBuildEngine()

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try LLBLabel("//some:target")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey).wait()) { error in
                guard let configuredTargetError = try? XCTUnwrap(error as? LLBConfiguredTargetError) else {
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

            let label = try LLBLabel("//some:notFound")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey).wait()) { error in
                guard let configuredTargetError = try? XCTUnwrap(error as? LLBConfiguredTargetError) else {
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
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let testEngine = LLBTestBuildEngine(configuredTargetDelegate: configuredTargetDelegate) { registry in
                registry.register(type: Int.self)
            }
            let registry = LLBSerializableRegistry()
            registry.register(type: Int.self)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try LLBLabel("//some:valid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let configuredTargetValue = try testEngine.build(configuredTargetKey, as: LLBConfiguredTargetValue.self).wait()
            let configuredTarget: Int = try configuredTargetValue.typedConfiguredTarget(registry: registry)
            XCTAssertEqual(configuredTarget, 1)
        }
    }
}
