// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Foundation
import LLBBuildSystem
import LLBBuildSystemTestHelpers
import LLBBuildSystemProtocol
import LLBCASFileTree
import LLBBuildSystemUtil
import TSCBasic
import XCTest

// Dummy configured target data structure.
private struct RuleEvaluationConfiguredTarget: ConfiguredTarget, Codable {
    let name: String
    let dependency: LLBProviderMap?

    init(name: String, dependency: LLBProviderMap? = nil) {
        self.name = name
        self.dependency = dependency
    }
}

private final class DummyBuildRule: LLBBuildRule<RuleEvaluationConfiguredTarget> {
    override func evaluate(configuredTarget: RuleEvaluationConfiguredTarget, _ ruleContext: RuleContext) throws -> LLBFuture<[LLBProvider]> {
        if configuredTarget.name == "single_artifact_valid" {
            let output = ruleContext.declareArtifact("single_artifact_valid")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output.path)"],
                inputs: [],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "2_outputs_2_actions" {
            let output1 = ruleContext.declareArtifact("output_1")
            let output2 = ruleContext.declareArtifact("output_2")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output1.path)"],
                inputs: [],
                outputs: [output1]
            )

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo I cant breathe > \(output2.path)"],
                inputs: [],
                outputs: [output2]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output1, output2])])
        } else if configuredTarget.name == "2_actions_1_output" {
            let output = ruleContext.declareArtifact("2_actions_1_output")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output.path)"],
                inputs: [],
                outputs: [output]
            )

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo I can't breathe > \(output.path)"],
                inputs: [],
                outputs: [output]
            )
        } else if configuredTarget.name == "unregistered_output"{
            _ = ruleContext.declareArtifact("unregistered_output")
            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [])])
        } else if configuredTarget.name == "bottom_level_target" {
            let output = ruleContext.declareArtifact("bottom_level_artifact")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output.path)"],
                inputs: [],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "top_level_target" {
            let output = ruleContext.declareArtifact("top_level_artifact")

            guard let bottomArtifact = try configuredTarget.dependency?.get(RuleEvaluationProvider.self).artifacts[0] else {
                throw StringError("Dependency did not have artifact.")
            }

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "cat \(bottomArtifact.path) > \(output.path); echo I cant breathe >> \(output.path)"],
                inputs: [bottomArtifact],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        }

        return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [])])
    }
}

fileprivate struct RuleEvaluationProvider: LLBProvider, Codable {
    let artifacts: [Artifact]

    init(artifacts: [Artifact]) {
        self.artifacts = artifacts
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: ConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) throws -> LLBFuture<ConfiguredTarget> {
        if key.label.targetName == "top_level_target" {
            let dependencyKey = ConfiguredTargetKey(rootID: key.rootID, label: try Label("//some:bottom_level_target"))
            return fi.requestDependency(dependencyKey).map { providerMap in
                return RuleEvaluationConfiguredTarget(name: key.label.targetName, dependency: providerMap)
            }
        }

        return fi.group.next().makeSucceededFuture(RuleEvaluationConfiguredTarget(name: key.label.targetName))
    }
}

private final class DummyRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        RuleEvaluationConfiguredTarget.identifier: DummyBuildRule(),
    ]

    func rule(for configuredTargetType: ConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.identifier]
    }
}

class RuleEvaluationTests: XCTestCase {
    func testRuleEvaluation() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: RuleEvaluationConfiguredTarget.self)

            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:single_artifact_valid")
            let configuredTargetKey = ConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: EvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: ArtifactValue = try testEngine.build(outputArtifact).wait()

            let artifactContents = try XCTUnwrap(testEngine.testDB.get(artifactValue.dataID).wait()?.data.asString())
            XCTAssertEqual(artifactContents, "black lives matter\n")
        }
    }

    func testRuleEvaluation2Outputs2Actions() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: RuleEvaluationConfiguredTarget.self)

            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:2_outputs_2_actions")
            let configuredTargetKey = ConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: EvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            for (index, artifact) in try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts.enumerated() {
                let artifactValue: ArtifactValue = try testEngine.build(artifact).wait()

                let artifactContents = try XCTUnwrap(testEngine.testDB.get(artifactValue.dataID).wait()?.data.asString())

                switch index {
                case 0:
                    XCTAssertEqual(artifactContents, "black lives matter\n")
                case 1:
                    XCTAssertEqual(artifactContents, "I cant breathe\n")
                default:
                    XCTFail("Unexpected output")
                }
            }
        }
    }

    func testRuleEvaluation2ActionsWithSameOutput() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: RuleEvaluationConfiguredTarget.self)

            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:2_actions_1_output")
            let configuredTargetKey = ConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            XCTAssertThrowsError(try testEngine.build(evaluatedTargetKey).wait()) { error in
                guard let ruleContextError = error as? RuleContextError else {
                    XCTFail("unexpected error type")
                    return
                }
                guard case .outputAlreadyRegistered = ruleContextError else {
                    XCTFail("unexpected error type")
                    return
                }
            }
        }
    }

    func testRuleEvaluationUnregisteredOutput() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: RuleEvaluationConfiguredTarget.self)

            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:unregistered_output")
            let configuredTargetKey = ConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            XCTAssertThrowsError(try testEngine.build(evaluatedTargetKey).wait()) { error in
                guard let ruleContextError = error as? RuleEvaluationError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
                guard case let .unassignedOutput(artifact) = ruleContextError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }

                XCTAssertEqual(artifact.shortPath, "unregistered_output")
            }
        }
    }

    func testRuleEvaluation2Targets() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: RuleEvaluationConfiguredTarget.self)

            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:top_level_target")
            let configuredTargetKey = ConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: EvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: ArtifactValue = try testEngine.build(outputArtifact).wait()

            let artifactContents = try XCTUnwrap(testEngine.testDB.get(artifactValue.dataID).wait()?.data.asString())
            XCTAssertEqual(artifactContents, "black lives matter\nI cant breathe\n")
        }
    }
}
