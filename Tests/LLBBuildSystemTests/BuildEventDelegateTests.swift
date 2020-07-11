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
import LLBBuildSystemUtil
import TSCBasic
import XCTest

// Dummy configured target data structure.
private struct DummyConfiguredTarget: LLBConfiguredTarget {
    let name: String

    init(name: String) {
        self.name = name
    }

    var targetDependencies: [String: LLBTargetDependency] { [:] }

    init(from bytes: LLBByteBuffer) throws {
        self.name = try String(from: bytes)
    }

    func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeString(name)
    }
}

private final class DummyBuildRule: LLBBuildRule<DummyConfiguredTarget> {
    override func evaluate(configuredTarget: DummyConfiguredTarget, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        let output = try ruleContext.declareArtifact("someOutput")

        if ruleContext.label.targetName == "invalid" {
            try ruleContext.registerAction(arguments: ["/usr/bin/wrong_command", output.path], inputs: [], outputs: [output])
        } else {
            try ruleContext.registerAction(arguments: ["/usr/bin/touch", output.path], inputs: [], outputs: [output])
        }

        return ruleContext.group.next().makeSucceededFuture([DummyProvider(output: output)])
    }
}

fileprivate struct DummyProvider: LLBProvider, Codable {
    let output: LLBArtifact

    init(output: LLBArtifact) {
        self.output = output
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<LLBConfiguredTarget> {
        return ctx.group.next().makeSucceededFuture(DummyConfiguredTarget(name: key.label.targetName))
    }
}

private final class DummyRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        DummyConfiguredTarget.polymorphicIdentifier: DummyBuildRule(),
    ]

    func rule(for configuredTargetType: LLBConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.polymorphicIdentifier]
    }
}

private final class DummyBuildEventDelegate: LLBBuildEventDelegate {
    var receivedEvents = [String: Int]()
    var seenActions = Set<String>()
    var seenLabels = Set<LLBLabel>()
    let semaphore = DispatchSemaphore(value: 1)

    func markEvent(_ event: String) {
        semaphore.wait()
        receivedEvents[event] = receivedEvents[event, default: 0] + 1
        semaphore.signal()
    }

    func targetEvaluationRequested(label: LLBLabel) {
        markEvent("evaluationRequested \(label.canonical)")

        semaphore.wait()
        seenLabels.insert(label)
        semaphore.signal()
    }

    func targetEvaluationCompleted(label: LLBLabel) {
        markEvent("evaluationCompleted \(label.canonical)")
    }

    func actionScheduled(action: LLBBuildEventActionDescription) {
        markEvent("actionScheduled \(action.identifier)")

        semaphore.wait()
        seenActions.insert(action.identifier)
        semaphore.signal()
    }

    func actionCompleted(action: LLBBuildEventActionDescription) {
        markEvent("actionCompleted \(action.identifier)")
    }

    func actionExecutionStarted(action: LLBBuildEventActionDescription) {
        markEvent("actionExecutionStarted \(action.identifier)")
    }

    func actionExecutionCompleted(action: LLBBuildEventActionDescription, result: LLBActionResult) {
        markEvent("actionExecutionCompleted \(action.identifier)")
    }
}


class BuildEventDelegateTests: XCTestCase {
    let expectedEvaluationEvents = [
        "evaluationRequested",
        "evaluationCompleted",
    ]

    let expectedActionEvents = [
        "actionScheduled",
        "actionCompleted",
        "actionExecutionStarted",
        "actionExecutionCompleted"
    ]

    func testSuccessAction() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            var ctx = LLBMakeTestContext()

            let buildEventDelegate = DummyBuildEventDelegate()
            ctx.buildEventDelegate = buildEventDelegate

            let localExecutor = LLBLocalExecutor(outputBase: tempDir)

            let
                testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: DummyConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:valid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            let outputArtifact = try evaluatedTargetValue.providerMap.get(DummyProvider.self).output

            _ = try testEngine.build(outputArtifact, ctx).wait()

            // Check that events appeared once and only once per target and action
            for identifier in buildEventDelegate.seenActions {
                for event in expectedActionEvents {
                    XCTAssertEqual(buildEventDelegate.receivedEvents["\(event) \(identifier)"], 1)
                }
            }

            for label in buildEventDelegate.seenLabels {
                for event in expectedEvaluationEvents {
                    XCTAssertEqual(buildEventDelegate.receivedEvents["\(event) \(label.canonical)"], 1)
                }
            }
        }
    }

    func testFailureAction() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            var ctx = LLBMakeTestContext()

            let buildEventDelegate = DummyBuildEventDelegate()
            ctx.buildEventDelegate = buildEventDelegate

            let localExecutor = LLBLocalExecutor(outputBase: tempDir)

            let
                testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: DummyConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:invalid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            let outputArtifact = try evaluatedTargetValue.providerMap.get(DummyProvider.self).output

            // Don't throw on failure, we're explicitly failing this to check the delegate events
            _ = try? testEngine.build(outputArtifact, ctx).wait()

            // Check that events appeared once and only once per target and action
            for identifier in buildEventDelegate.seenActions {
                for event in expectedActionEvents {
                    XCTAssertEqual(buildEventDelegate.receivedEvents["\(event) \(identifier)"], 1)
                }
            }

            for label in buildEventDelegate.seenLabels {
                for event in expectedEvaluationEvents {
                    XCTAssertEqual(buildEventDelegate.receivedEvents["\(event) \(label.canonical)"], 1)
                }
            }
        }
    }
}
