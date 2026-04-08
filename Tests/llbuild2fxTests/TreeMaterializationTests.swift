// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import TSCBasic
import XCTest

import llbuild2Testing
import llbuild2fx

// A concrete FXTreeID for testing.
private struct TestTreeID: FXSingleDataIDValue, FXTreeID {
    let dataID: FXDataID
    init(dataID: FXDataID) {
        self.dataID = dataID
    }
}

// A concrete FXFileID for testing.
private struct TestFileID: FXSingleDataIDValue, FXFileID {
    let dataID: FXDataID
    init(dataID: FXDataID) {
        self.dataID = dataID
    }
}

final class TreeMaterializationTests: XCTestCase {
    var ctx: Context!
    var db: FXInMemoryCASDatabase!
    var treeService: FXLocalCASTreeService!

    override func setUp() {
        ctx = Context()
        db = FXInMemoryCASDatabase(group: FXMakeDefaultDispatchGroup())
        ctx.group = db.group
        treeService = FXLocalCASTreeService(db: db)
    }

    // MARK: - Tree Import and Export via CASTreeService

    func testImportAndExportTree() async throws {
        // Create a directory with files on disk
        try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { srcDir in
            try "hello world".write(toFile: srcDir.appending(component: "greeting.txt").pathString, atomically: true, encoding: .utf8)
            try "data".write(toFile: srcDir.appending(component: "info.txt").pathString, atomically: true, encoding: .utf8)

            // Import the tree into CAS
            let treeID = try await treeService.importTree(path: srcDir, ctx)

            // Export it back to a new directory
            try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { dstDir in
                try await treeService.export(treeID, to: dstDir, ctx)

                let greeting = try String(contentsOfFile: dstDir.appending(component: "greeting.txt").pathString, encoding: .utf8)
                XCTAssertEqual(greeting, "hello world")

                let info = try String(contentsOfFile: dstDir.appending(component: "info.txt").pathString, encoding: .utf8)
                XCTAssertEqual(info, "data")
            }
        }
    }

    // MARK: - FXTreeID.materialize (async)

    func testTreeIDMaterialize() async throws {
        let treeID = try await importSingleFileTree(filename: "test.txt", content: "tree content")
        let testTree = TestTreeID(treeID)

        try await testTree.materialize(treeService, ctx) { rootPath in
            let content = try String(contentsOfFile: rootPath.appending(component: "test.txt").pathString, encoding: .utf8)
            XCTAssertEqual(content, "tree content")
        }
    }

    func testTreeIDMaterializeMultipleFiles() async throws {
        try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { srcDir in
            try "aaa".write(toFile: srcDir.appending(component: "a.txt").pathString, atomically: true, encoding: .utf8)
            try "bbb".write(toFile: srcDir.appending(component: "b.txt").pathString, atomically: true, encoding: .utf8)

            let treeID = try await treeService.importTree(path: srcDir, ctx)
            let testTree = TestTreeID(treeID)

            try await testTree.materialize(treeService, ctx) { rootPath in
                let a = try String(contentsOfFile: rootPath.appending(component: "a.txt").pathString, encoding: .utf8)
                let b = try String(contentsOfFile: rootPath.appending(component: "b.txt").pathString, encoding: .utf8)
                XCTAssertEqual(a, "aaa")
                XCTAssertEqual(b, "bbb")
            }
        }
    }

    // MARK: - FXTreeID.materialize (NIO futures)

    func testTreeIDMaterializeFutures() async throws {
        let treeID = try await importSingleFileTree(filename: "future.txt", content: "futures!")
        let testTree = TestTreeID(treeID)

        let result: String = try await testTree.materialize(treeService, ctx) { rootPath in
            try String(contentsOfFile: rootPath.appending(component: "future.txt").pathString, encoding: .utf8)
        }

        XCTAssertEqual(result, "futures!")
    }

    // MARK: - FXFileID.materialize (async)

    func testFileIDMaterialize() async throws {
        let fileID = try await importSingleFile(filename: "single.txt", content: "file content")
        let testFile = TestFileID(fileID)

        try await testFile.materialize(filename: "single.txt", treeService: treeService, ctx) { filePath in
            let content = try String(contentsOfFile: filePath.pathString, encoding: .utf8)
            XCTAssertEqual(content, "file content")
        }
    }

    // MARK: - FXFileID.materialize (NIO futures)

    func testFileIDMaterializeFutures() async throws {
        let fileID = try await importSingleFile(filename: "nio.txt", content: "nio content")
        let testFile = TestFileID(fileID)

        let result: String = try await testFile.materialize(filename: "nio.txt", treeService: treeService, ctx) { filePath in
            try String(contentsOfFile: filePath.pathString, encoding: .utf8)
        }

        XCTAssertEqual(result, "nio content")
    }

    // MARK: - FXTreeMaterializer Context Property

    func testTreeMaterializerContextProperty() {
        var localCtx = Context()
        XCTAssertNil(localCtx.fxTreeMaterializer)
    }

    // MARK: - withTemporaryDirectory Helpers

    func testWithTemporaryDirectoryAsync() async throws {
        var dirExisted = false
        try await llbuild2fx.withTemporaryDirectory(ctx) { tmpDir in
            dirExisted = FileManager.default.fileExists(atPath: tmpDir.pathString)
        }
        XCTAssertTrue(dirExisted)
    }

    func testWithTemporaryDirectoryFutures() throws {
        let result: Bool = try llbuild2fx.withTemporaryDirectory(ctx) { tmpDir -> FXFuture<Bool> in
            let exists = FileManager.default.fileExists(atPath: tmpDir.pathString)
            return self.ctx.group.next().makeSucceededFuture(exists)
        }.wait()
        XCTAssertTrue(result)
    }

    // MARK: - Helpers

    /// Import a single-file directory tree into CAS and return the tree's data ID.
    private func importSingleFileTree(filename: String, content: String) async throws -> FXDataID {
        return try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
            try content.write(toFile: tmpDir.appending(component: filename).pathString, atomically: true, encoding: .utf8)
            return try await treeService.importTree(path: tmpDir, ctx)
        }
    }

    /// Import a single file into CAS as a blob and return its data ID.
    private func importSingleFile(filename: String, content: String) async throws -> FXDataID {
        let data = FXByteBuffer.withBytes(Array(content.utf8))
        let blob = try await FXCASBlob.import(data: data, isExecutable: false, in: db, ctx).get()
        return try await blob.export(ctx).get()
    }
}
