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
}
