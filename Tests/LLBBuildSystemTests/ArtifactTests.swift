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

// This should actually be a testable import but it's not working for some reason.
private extension LLBArtifact {
    func _updateOwner(owner: LLBArtifactOwner) {
        precondition(originType == nil, "Artifact was already associated to an action")
        self.originType = .derived(owner)
    }
}

class ArtifactTests: XCTestCase {
    func testSourceArtifact() throws {
        let ctx = LLBMakeTestContext()
        let testEngine = LLBTestBuildEngine(group: ctx.group, db: ctx.db)

        let bytes = LLBByteBuffer.withString("Hello, world!")
        let dataID = try ctx.db.put(data: bytes, ctx).wait()
        let artifact = LLBArtifact.source(shortPath: "someSource", dataID: dataID)

        let artifactValue: LLBArtifactValue = try testEngine.build(artifact, ctx).wait()
        XCTAssertEqual(Data(dataID.bytes), artifactValue.dataID.bytes)
    }
}
