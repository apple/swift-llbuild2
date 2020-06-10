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
import LLBBuildSystemUtil
import TSCBasic
import XCTest

// This should actually be a testable import but it's not working for some reason.
private extension Artifact {
    func _updateOwner(owner: LLBArtifactOwner) {
        precondition(originType == nil, "Artifact was already associated to an action")
        self.originType = .derived(owner)
    }
}

class ArtifactTests: XCTestCase {
    func testSourceArtifact() throws {
        let testEngine = LLBTestBuildEngine()

        let bytes = LLBByteBuffer.withString("Hello, world!")
        let dataID = try testEngine.testDB.put(data: bytes).wait()
        let artifact = Artifact.source(shortPath: "someSource", dataID: dataID)

        let artifactValue: ArtifactValue = try testEngine.build(artifact).wait()
        XCTAssertEqual(Data(dataID.bytes), artifactValue.dataID.bytes)
    }

    func testDerivedArtifact() throws {
        try withTemporaryDirectory { tempDir in
            let localExecutor = LLBLocalExecutor(outputBase: tempDir)
            let testEngine = LLBTestBuildEngine(executor: localExecutor)

            let sourceContent = LLBByteBuffer.withString("black lives matter")
            let sourceID = try testEngine.testDB.put(data: sourceContent).wait()
            let sourceArtifact = Artifact.source(shortPath: "someSource", dataID: sourceID)

            let derivedArtifact = Artifact.derivedUninitialized(shortPath: "someDerived")


            let actionKey = ActionKey.command(
                actionSpec: LLBActionSpec.with {
                    $0.arguments = ["/bin/cp", sourceArtifact.path, derivedArtifact.path]
                },
                inputs: [sourceArtifact],
                outputs: [derivedArtifact.asActionOutput()]
            )

            let actionID = try testEngine.testDB.put(data: try actionKey.toBytes()).wait()

            derivedArtifact._updateOwner(owner: LLBArtifactOwner(actionID: actionID, outputIndex: 0))

            let derivedArtifactValue: ArtifactValue = try testEngine.build(derivedArtifact).wait()

            let derivedContents = try XCTUnwrap(testEngine.testDB.get(derivedArtifactValue.dataID).wait()?.data.asString())
            XCTAssertEqual(derivedContents, "black lives matter")

        }
    }
}
