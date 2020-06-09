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

// Dummy configured target data structure.
private struct DummyConfiguredTarget: ConfiguredTarget {
    let name: String
    
    init(name: String) {
        self.name = name
    }
    
    init(from bytes: LLBByteBuffer) throws {
        self.name = try String(from: bytes)
    }
    
    func encode() throws -> LLBByteBuffer {
        return LLBByteBuffer.withString(name)
    }
}

private final class DummyBuildRule: LLBBuildRule<DummyConfiguredTarget> {
    override func evaluate(configuredTarget: DummyConfiguredTarget, _ ruleContext: RuleContext) -> LLBFuture<[LLBProvider]> {
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
    
    func encode() throws -> LLBByteBuffer {
        return LLBByteBuffer.withString(simpleString)
    }
}

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: ConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ConfiguredTarget> {
        return fi.group.next().makeSucceededFuture(DummyConfiguredTarget(name: key.label.targetName))
    }
}

private final class DummyRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        DummyConfiguredTarget.polymorphicIdentifier: DummyBuildRule(),
    ]
    
    func rule(for configuredTargetType: ConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.polymorphicIdentifier]
    }
}

class EvaluatedTargetTests: XCTestCase {
    func testEvaluatedTarget() throws {
        try withTemporaryDirectory { tempDir in
            ConfiguredTargetValue.register(configuredTargetType: DummyConfiguredTarget.self)
            
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let ruleLookupDelegate = DummyRuleLookupDelegate()
            let testEngine = LLBTestBuildEngine(
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:valid")
            let configuredTargetKey = ConfiguredTargetKey(rootID: LLBPBDataID(dataID), label: label)
            
            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: EvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap.count, 1)
            XCTAssertEqual(try evaluatedTargetValue.providerMap.get(DummyProvider.self).simpleString, "black lives matter")
        }
    }
}
