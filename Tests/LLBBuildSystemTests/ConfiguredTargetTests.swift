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
import LLBUtil
import TSCBasic
import XCTest

extension Int: LLBConfiguredTarget {
    public var targetDependencies: [String: LLBTargetDependency] { [:] }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBConfiguredTarget> {
        if key.label.targetName == "notFound" {
            return ctx.group.next().makeFailedFuture(LLBConfiguredTargetError.notFound(key.label))
        }
        return ctx.group.next().makeSucceededFuture(1)
    }
}

class ConfiguredTargetTests: XCTestCase {
    func testNoDelegateConfigured() throws {
        try withTemporaryDirectory { tempDir in
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(group: ctx.group, db: ctx.db)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:target")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey, ctx).wait()) { error in
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
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(group: ctx.group, db: ctx.db, configuredTargetDelegate: configuredTargetDelegate)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:notFound")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            XCTAssertThrowsError(try testEngine.build(configuredTargetKey, ctx).wait()) { error in
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
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(group: ctx.group, db: ctx.db, configuredTargetDelegate: configuredTargetDelegate) { registry in
                registry.register(type: Int.self)
            }
            let registry = LLBSerializableRegistry()
            registry.register(type: Int.self)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:valid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let configuredTargetValue = try testEngine.build(configuredTargetKey, as: LLBConfiguredTargetValue.self, ctx).wait()
            let configuredTarget: Int = try configuredTargetValue.typedConfiguredTarget(registry: registry)
            XCTAssertEqual(configuredTarget, 1)
        }
    }
}
