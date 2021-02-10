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
import LLBBuildSystemUtil
import TSCBasic
import XCTest

// Dummy configured target data structure.
private struct RuleEvaluationConfiguredTarget: LLBConfiguredTarget, Codable {
    let name: String
    let dependency: LLBLabel?

    init(name: String, dependency: LLBLabel? = nil) {
        self.name = name
        self.dependency = dependency
    }
    
    var targetDependencies: [String : LLBTargetDependency] {
        if let dependency = dependency {
            return ["dependency": .single(dependency)]
        }
        return [:]
    }
}

private final class DummyBuildRule: LLBBuildRule<RuleEvaluationConfiguredTarget> {
    override func evaluate(configuredTarget: RuleEvaluationConfiguredTarget, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        if configuredTarget.name == "single_artifact_valid" {
            let output = try ruleContext.declareArtifact("single_artifact_valid")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output.path)"],
                inputs: [],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "2_outputs_2_actions" {
            let output1 = try ruleContext.declareArtifact("output_1")
            let output2 = try ruleContext.declareArtifact("output_2")

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
            let output = try ruleContext.declareArtifact("2_actions_1_output")

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
            _ = try ruleContext.declareArtifact("unregistered_output")
            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [])])
        } else if configuredTarget.name == "bottom_level_target" {
            let output = try ruleContext.declareArtifact("bottom_level_artifact")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "echo black lives matter > \(output.path)"],
                inputs: [],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "bottom_level_target_failed" {
            let output = try ruleContext.declareArtifact("bottom_level_artifact")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "exit 1"],
                inputs: [],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "top_level_target" {
            let output = try ruleContext.declareArtifact("top_level_artifact")

            guard let provider: RuleEvaluationProvider = try? ruleContext.getProvider(for: "dependency") else {
                throw StringError("Dependency did not have artifact.")
            }
            
            let bottomArtifact = provider.artifacts[0]

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "cat \(bottomArtifact.path) > \(output.path); echo I cant breathe >> \(output.path)"],
                inputs: [bottomArtifact],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "top_level_target_with_failed_dependency" {
            let output = try ruleContext.declareArtifact("top_level_artifact")

            guard let provider: RuleEvaluationProvider = try? ruleContext.getProvider(for: "dependency") else {
                throw StringError("Dependency did not have artifact.")
            }

            let bottomArtifact = provider.artifacts[0]

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "cat \(bottomArtifact.path) > \(output.path); echo I cant breathe >> \(output.path)"],
                inputs: [bottomArtifact],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "static_write" {
            let output = try ruleContext.declareArtifact("static_write")

            try ruleContext.write(contents: "black lives matter", to: output)
            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "tree_merge" {
            let directory1 = try ruleContext.declareDirectoryArtifact("directory1")
            let directory2 = try ruleContext.declareDirectoryArtifact("directory2")
            let output = try ruleContext.declareDirectoryArtifact("output")

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "mkdir -p \(directory1.path); echo I cant breathe > \(directory1.path)/file1.txt"],
                inputs: [],
                outputs: [directory1]
            )

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "mkdir -p \(directory2.path); echo black lives matter > \(directory2.path)/file2.txt"],
                inputs: [],
                outputs: [directory2]
            )

            try ruleContext.registerMergeDirectories(
                [
                    (directory1, "directory1"),
                    (directory2, "directory2"),
                ],
                output: output
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
        } else if configuredTarget.name == "tree_merge_file_output_error" {
            let output = try ruleContext.declareArtifact("shouldBeDirectory")

            try ruleContext.registerMergeDirectories(
                [],
                output: output
            )

            return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [output])])
}

        return ruleContext.group.next().makeSucceededFuture([RuleEvaluationProvider(artifacts: [])])
    }
}

fileprivate struct RuleEvaluationProvider: LLBProvider, Codable {
    let artifacts: [LLBArtifact]

    init(artifacts: [LLBArtifact]) {
        self.artifacts = artifacts
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) throws -> LLBFuture<LLBConfiguredTarget> {
        let configuredTarget: RuleEvaluationConfiguredTarget
        if key.label.targetName == "top_level_target" {
            configuredTarget = RuleEvaluationConfiguredTarget(
                name: key.label.targetName,
                dependency: try LLBLabel("//some:bottom_level_target")
            )
        } else if key.label.targetName == "top_level_target_with_failed_dependency" {
            configuredTarget = RuleEvaluationConfiguredTarget(
                name: key.label.targetName,
                dependency: try LLBLabel("//some:bottom_level_target_failed")
            )
        } else {
            configuredTarget = RuleEvaluationConfiguredTarget(name: key.label.targetName)
        }

        return ctx.group.next().makeSucceededFuture(configuredTarget)
    }
}

private final class DummyRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        RuleEvaluationConfiguredTarget.identifier: DummyBuildRule(),
    ]

    func rule(for configuredTargetType: LLBConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.identifier]
    }
}

class RuleEvaluationTests: XCTestCase {
    func testRuleEvaluation() throws {
        try withTemporaryDirectory { tempDir in
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:single_artifact_valid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: LLBArtifactValue = try testEngine.build(outputArtifact, ctx).wait()

            let artifactContents = try LLBCASFSClient(ctx.db).fileContents(for: artifactValue.dataID, ctx)
            XCTAssertEqual(artifactContents, "black lives matter\n")
        }
    }

    func testRuleEvaluation2Outputs2Actions() throws {
        try withTemporaryDirectory { tempDir in
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:2_outputs_2_actions")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            for (index, artifact) in try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts.enumerated() {
                let artifactValue: LLBArtifactValue = try testEngine.build(artifact, ctx).wait()

                let artifactContents = try LLBCASFSClient(ctx.db).fileContents(for: artifactValue.dataID, ctx)

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
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:2_actions_1_output")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            XCTAssertThrowsError(try testEngine.build(evaluatedTargetKey, ctx).wait()) { error in
                guard let evaluationError = error as? LLBRuleEvaluationError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
                guard case let .ruleEvaluationError(innerError) = evaluationError,
                      let ruleContextError = innerError as? LLBRuleContextError else {
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
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:unregistered_output")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            XCTAssertThrowsError(try testEngine.build(evaluatedTargetKey, ctx).wait()) { error in
                guard let ruleContextError = error as? LLBRuleEvaluationError else {
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
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:top_level_target")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: LLBArtifactValue = try testEngine.build(outputArtifact, ctx).wait()

            let artifactContents = try LLBCASFSClient(ctx.db).fileContents(for: artifactValue.dataID, ctx)
            XCTAssertEqual(artifactContents, "black lives matter\nI cant breathe\n")
        }
    }

    func testRuleEvaluation2TargetsWithFailureOnDependency() throws {
        try withTemporaryDirectory { tempDir in
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:top_level_target_with_failed_dependency")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            XCTAssertThrowsError(try testEngine.build(outputArtifact, ctx).wait()) { error in
                guard let actionError = error as? LLBActionError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }

                guard case let .dependencyFailure(innerError) = actionError,
                      let innerActionError = innerError as? LLBActionExecutionError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
                guard case .actionExecutionError = innerActionError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
            }
        }
    }

    func testRuleEvaluationStaticWrite() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:static_write")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: LLBArtifactValue = try testEngine.build(outputArtifact, ctx).wait()

            let artifactContents = try XCTUnwrap(ctx.db.get(artifactValue.dataID, ctx).wait()?.data.asString())
            XCTAssertEqual(artifactContents, "black lives matter")
        }
    }

    func testRuleEvaluationTreeMerge() throws {
        try withTemporaryDirectory { tempDir in
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:tree_merge")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            let outputArtifact = try evaluatedTargetValue.providerMap.get(RuleEvaluationProvider.self).artifacts[0]

            let artifactValue: LLBArtifactValue = try testEngine.build(outputArtifact, ctx).wait()

            let client = LLBCASFSClient(ctx.db)

            // FIXME: There should be an easier way to read files from a CASFileTree, perhaps using a CAS based
            // FileSystem protocol implementation?
            let (file1Contents, file2Contents): (String, String) = try client.load(artifactValue.dataID, ctx).flatMap { node in
                let tree = node.tree!
                let file1Contents = client.load(try! XCTUnwrap(tree.lookup("directory1")).id, ctx).flatMap { node -> LLBFuture<String> in
                    let tree = node.tree!
                    return client.load(try! XCTUnwrap(tree.lookup("file1.txt")).id, ctx).flatMap { node in
                        return node.blob!.read(ctx).map { String(data: Data($0), encoding: .utf8)! }
                    }
                }
                let file2Contents = client.load(try! XCTUnwrap(tree.lookup("directory2")).id, ctx).flatMap { node -> LLBFuture<String> in
                    let tree = node.tree!
                    return client.load(try! XCTUnwrap(tree.lookup("file2.txt")).id, ctx).flatMap { node in
                        return node.blob!.read(ctx).map { String(data: Data($0), encoding: .utf8)! }
                    }
                }
                return file1Contents.and(file2Contents)
            }.wait()

            XCTAssertEqual(file1Contents, "I cant breathe\n")
            XCTAssertEqual(file2Contents, "black lives matter\n")
        }
    }

    func testOutputForMergeIsFile() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let ctx = LLBMakeTestContext()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            ) { registry in
                registry.register(type: RuleEvaluationConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:tree_merge_file_output_error")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            XCTAssertThrowsError(try testEngine.build(evaluatedTargetKey, ctx).wait()) { error in
                guard let evaluationError = error as? LLBRuleEvaluationError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }

                guard case let .ruleEvaluationError(innerError) = evaluationError,
                      let ruleContextError = innerError as? LLBRuleContextError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
                guard case .mergeDirectoriesIntoFileError = ruleContextError else {
                    XCTFail("unexpected error type \(error)")
                    return
                }
            }
        }
    }
}
