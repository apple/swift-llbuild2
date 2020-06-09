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
struct DummyConfiguredTarget: ConfiguredTarget {
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

private final class DummyConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: ConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ConfiguredTarget> {
        return fi.group.next().makeSucceededFuture(DummyConfiguredTarget(name: key.label.targetName))
    }
}

class EvaluatedTargetTests: XCTestCase {
    func testEvaluatedTarget() throws {
        try withTemporaryDirectory { tempDir in
            let configuredTargetDelegate = DummyConfiguredTargetDelegate()
            let testEngine = LLBTestBuildEngine(configuredTargetDelegate: configuredTargetDelegate)

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try Label("//some:valid")
            let configuredTargetKey = ConfiguredTargetKey(rootID: LLBPBDataID(dataID), label: label)
            
            let evaluatedTargetKey = EvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: EvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            XCTAssertEqual(evaluatedTargetValue.providerMap, LLBProviderMap())
        }
    }
}
