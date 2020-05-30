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
import XCTest

class ArtifactTests: XCTestCase {
    func testSourceArtifact() throws {
        let testEngine = LLBTestBuildEngine()

        let contents = "Hello, world!"

        let bytes = LLBByteBuffer.withData(try XCTUnwrap(contents.data(using: .utf8)))
        let dataID = try testEngine.db.put(refs: [], data: bytes).wait()
        let artifact = Artifact.source(shortPath: "someSource", dataID: LLBPBDataID(dataID))

        let artifactValue: ArtifactValue = try testEngine.build(artifact).wait()
        XCTAssertEqual(LLBPBDataID(dataID), artifactValue.dataID)
    }
}
