// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import FXAsyncSupport
import TSCBasic
import FXAsyncSupport
import TSCUtility
import FXAsyncSupport
import llbuild2Testing
import FXAsyncSupport
import XCTest

class CASBlobTests: XCTestCase {
    var group: FXFuturesDispatchGroup!

    override func setUp() {
        group = FXMakeDefaultDispatchGroup()
    }

    override func tearDown() {
        try! group.syncShutdownGracefully()
        group = nil
    }

    func testBasics() throws {
        try withTemporaryFile(suffix: ".dat") { tmp in
            // Check several chunk sizes, to probe boundary conditions.
            try checkOneBlob(tmp, chunkSize: 16, [UInt8](repeating: 1, count: 512))
            try checkOneBlob(tmp, chunkSize: 1024, [UInt8](repeating: 1, count: 512))

            // Compression only works with larger objects, due to hard coded constants in importer.
            try checkOneBlob(tmp, chunkSize: 1024, [UInt8](repeating: 1, count: 2048))
        }
    }

    func checkOneBlob(_ tmp: TemporaryFile, chunkSize: Int, _ contents: [UInt8]) throws {
        try localFileSystem.writeFileContents(tmp.path, bytes: ByteString(contents))

        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try FXCASFileTree.import(
            path: tmp.path, to: db,
            options: FXCASFileTree.ImportOptions(fileChunkSize: chunkSize), stats: nil, ctx
        ).wait()

        let blob = try FXCASBlob.parse(id: id, in: db, ctx).wait()
        XCTAssertEqual(blob.size, contents.count)

        // Check various read patterns.
        for testRange in [0..<0, 0..<1, 0..<contents.count, 10..<20, 20..<128, 128..<512] {

            let blobRange = try blob.read(range: testRange, ctx).wait()
            let bytes: [UInt8] = Array(
                FXByteBuffer(blobRange).readableBytesView.prefix(testRange.count))
            XCTAssertEqual(ArraySlice(bytes), contents[testRange])
        }
    }
}
