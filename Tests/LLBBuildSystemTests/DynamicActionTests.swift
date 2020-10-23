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

extension String: LLBConfiguredTarget {
    public var targetDependencies: [String: LLBTargetDependency] { [:] }
}

private final class DummyBuildRule: LLBBuildRule<String> {
    override func evaluate(configuredTarget: String, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        if configuredTarget == "simple_action" {
            let input = try ruleContext.declareArtifact("input.txt")
            let dynamicOutput = try ruleContext.declareArtifact("dynamicOutput.txt")
            let output = try ruleContext.declareArtifact("output.txt")

            try ruleContext.write(contents: "black lives matter", to: input)

            try ruleContext.registerDynamicAction(
                DynamicActionExecutor.self,
                arguments: ["custom_command", "black lives matter"],
                inputs: [input],
                outputs: [dynamicOutput]
            )

            try ruleContext.registerAction(
                arguments: ["/bin/bash", "-c", "cat \(dynamicOutput.path) > \(output.path)"],
                inputs: [dynamicOutput],
                outputs: [output]
            )

            return ruleContext.group.next().makeSucceededFuture([DynamicActionProvider(artifact: output)])
        }

        return ruleContext.group.next().makeSucceededFuture([])
    }
}

fileprivate struct DynamicActionProvider: LLBProvider, Codable {
    let artifact: LLBArtifact

    init(artifact: LLBArtifact) {
        self.artifact = artifact
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) throws -> LLBFuture<LLBConfiguredTarget> {
        return ctx.group.next().makeSucceededFuture(key.label.targetName)
    }
}

private final class DummyRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        String.identifier: DummyBuildRule(),
    ]

    func rule(for configuredTargetType: LLBConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.identifier]
    }
}

private final class DynamicActionExecutor: LLBDynamicActionExecutor {
    func execute(
        request: LLBActionExecutionRequest,
        _ fi: LLBDynamicFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionExecutionResponse> {
        let input = request.inputs[0]
        let output = request.outputs[0]

        let intermediate = LLBActionOutput(path: "intermediateFile.txt", type: .file)

        let actionExecutionKey = LLBActionExecutionKey.command(
            arguments: ["/bin/bash", "-c", "cat \(input.path) > \(intermediate.path)"],
            inputs: [input],
            outputs: [intermediate]
        )

        return fi.requestActionExecution(actionExecutionKey, ctx).flatMap { actionResult in

            let intermediateInput = LLBActionInput(path: intermediate.path, dataID: actionResult.outputs[0], type: intermediate.type)

            let actionExecutionKey = LLBActionExecutionKey.command(
                arguments: ["/bin/bash", "-c", "cat \(intermediateInput.path) > \(output.path)"],
                inputs: [intermediateInput],
                outputs: [output]
            )

            return fi.requestActionExecution(actionExecutionKey, ctx)
        }.map { (actionResult: LLBActionExecutionValue) in
            return LLBActionExecutionResponse(outputs: actionResult.outputs, stdoutID: actionResult.stdoutID)
        }
    }
}

private final class DynamicActionExecutorDelegate: LLBDynamicActionExecutorDelegate {
    let dynamicExecutorMap: [LLBDynamicActionIdentifier: LLBDynamicActionExecutor] = [
        DynamicActionExecutor.identifier: DynamicActionExecutor(),
    ]

    func dynamicActionExecutor(for identifier: LLBDynamicActionIdentifier) -> LLBDynamicActionExecutor? {
        return dynamicExecutorMap[identifier]
    }
}

class DynamicActionTests: XCTestCase {
    func testDynamicAction() throws {
        try withTemporaryDirectory { tempDir in
            let ctx = LLBMakeTestContext()
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let dynamicExecutorDelegate = DynamicActionExecutorDelegate()
            let testEngine = LLBTestBuildEngine(
                group: ctx.group,
                db: ctx.db,
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate,
                dynamicActionExecutorDelegate: dynamicExecutorDelegate,
                executor: localExecutor
            ) { registry in
                registry.register(type: String.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: ctx.db, ctx).wait()

            let label = try LLBLabel("//some:simple_action")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey, ctx).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            let outputArtifact = try evaluatedTargetValue.providerMap.get(DynamicActionProvider.self).artifact

            let artifactValue: LLBArtifactValue = try testEngine.build(outputArtifact, ctx).wait()

            let artifactContents = try LLBCASFSClient(ctx.db).fileContents(for: artifactValue.dataID, ctx)
            XCTAssertEqual(artifactContents, "black lives matter")
        }
    }
}
