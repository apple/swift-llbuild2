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

// Dummy configured target data structure.
private struct DummyConfiguredTarget: LLBConfiguredTarget {
    let name: String
    
    init(name: String) {
        self.name = name
    }
    
    init(from bytes: LLBByteBuffer) throws {
        self.name = try String(from: bytes)
    }
    
    func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeString(name)
    }
}

private final class DummyBuildRule: LLBBuildRule<DummyConfiguredTarget> {
    override func evaluate(configuredTarget: DummyConfiguredTarget, _ ruleContext: LLBRuleContext) -> LLBFuture<[LLBProvider]> {
        return ruleContext.group.next().makeSucceededFuture([DummyProvider(simpleString: "black lives matter")])
    }
}

fileprivate struct DummyProvider: LLBProvider {
    let simpleString: String
    
    init(simpleString: String) {
        self.simpleString = simpleString
    }
    
    init(from bytes: LLBByteBuffer) throws {
        self.simpleString = try String(from: bytes)
    }
    
    func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeString(simpleString)
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBConfiguredTarget> {
        return fi.group.next().makeSucceededFuture(DummyConfiguredTarget(name: key.label.targetName))
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

class EvaluatedTargetTests: XCTestCase {
    func testEvaluatedTarget() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            ) { registry in
                registry.register(type: DummyConfiguredTarget.self)
            }

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try LLBLabel("//some:valid")
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label)
            
            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            XCTAssertEqual(try evaluatedTargetValue.providerMap.get(DummyProvider.self).simpleString, "black lives matter")
        }
    }
}
