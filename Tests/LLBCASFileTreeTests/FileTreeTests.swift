// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import TSCBasic

import LLBCAS
import LLBCASFileTree
import LLBSupport
import LLBUtil


class LLBCASFileTreeTests: XCTestCase {
    var group: LLBFuturesDispatchGroup!

    override func setUp() {
        group = LLBMakeDefaultDispatchGroup()
    }

    override func tearDown() {
        try! group.syncShutdownGracefully()
        group = nil
    }

    func testBasics() throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let aInfo = LLBDirectoryEntry(name: "a", type: .plainFile, size: 1)
        let aID = try db.put(data: LLBByteBuffer.withBytes(ArraySlice("a".utf8))).wait()
        let bInfoExec = LLBDirectoryEntry(name: "b", type: .executable, size: 1)
        let bID = try db.put(data: LLBByteBuffer.withBytes(ArraySlice("b".utf8))).wait()
        let tree1 = try LLBCASFileTree.create(files: [.init(info: aInfo, id: aID), .init(info: bInfoExec, id: bID)], in: db).wait()
        let tree2 = try LLBCASFileTree(id: tree1.id, object: db.get(tree1.id).wait()!)

        XCTAssertEqual(tree1.id, tree2.id)
        XCTAssertEqual(tree1.lookup("a")?.info, aInfo)
        XCTAssertEqual(tree1.lookup("b")?.info, bInfoExec)
        XCTAssertEqual(tree1.lookup("c")?.info, nil)
        XCTAssertEqual(tree2.lookup("a")?.info, aInfo)
        XCTAssertEqual(tree2.lookup("b")?.info, bInfoExec)
        XCTAssertEqual(tree2.lookup("c")?.info, nil)
    }

    /// Check that create enforces ordering of the input.
    func testCreateOrdering() throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let aInfo = LLBDirectoryEntry(name: "a", type: .plainFile, size: 1)
        let aID = try db.put(data: LLBByteBuffer.withBytes(ArraySlice("a".utf8))).wait()
        let bInfoExec = LLBDirectoryEntry(name: "b", type: .executable, size: 1)
        let bID = try db.put(data: LLBByteBuffer.withBytes(ArraySlice("b".utf8))).wait()
        let tree1 = try LLBCASFileTree.create(files: [.init(info: aInfo, id: aID), .init(info: bInfoExec, id: bID)], in: db).wait()
        let tree2 = try LLBCASFileTree.create(files: [.init(info: bInfoExec, id: bID), .init(info: aInfo, id: aID)], in: db).wait()

        XCTAssertEqual(tree1.id, tree2.id)
    }

    func testLookup() throws {
        let db = LLBInMemoryCASDatabase(group: group)

        for N in [0, 1, 2, 5, 11, 100] {
            let files = (0 ..< N).map { LLBDirectoryEntry(name: "f\($0)", type: .plainFile, size: 0) }
            let fileData = try db.put(data: LLBByteBuffer.withBytes([])).wait()
            let tree = try LLBCASFileTree.create(files: files.map{ .init(info: $0, id: fileData) }, in: db).wait()

            // Check we can find each item correctly.
            for file in files {
                XCTAssertEqual(tree.lookup(file.name)?.info, file)

                // Also check negative search.
                XCTAssertEqual(tree.lookup(file.name+"x")?.info, nil)
            }
        }
    }

    func testLookupPath() throws {
        try checkLookupPath(
            of: AbsolutePath("/missing"),
            in: .dir(["a": .file([1])]),
            is: nil)
        try checkLookupPath(
            of: AbsolutePath("/a"),
            in: .dir(["a": .file([1])]),
            is: (LLBDataID(blake3hash: LLBByteBuffer.withBytes([1]), refs: []), LLBDirectoryEntry(name: "a", type: .plainFile, size: 1)))
        try checkLookupPath(
            of: AbsolutePath("/a/b"),
            in: .dir(["a": .dir([
                            "b": .file([1])
                        ])
                ]),
            is: (LLBDataID(blake3hash: LLBByteBuffer.withBytes([1]), refs: []), LLBDirectoryEntry(name: "b", type: .plainFile, size: 1)))
        try checkLookupPath(
            of: AbsolutePath("/a/b/c"),
            in: .dir(["a": .dir([
                            "b": .file([1])
                        ])
                ]),
            is: nil)

        let testSubtree = try LLBCASFSClient(LLBInMemoryCASDatabase(group: group)).storeDir(LLBDeclFileTree.dir([
                "b": .file([1])
            ])).wait()
        try checkLookupPath(
            of: AbsolutePath("/a"),
            in: .dir(["a": .dir([
                            "b": .file([1])
                        ])
                ]),
            is: (testSubtree.id, LLBDirectoryEntry(name: "a", type: .directory, size: testSubtree.aggregateSize)))
    }

    func testMerge() throws {
        try checkMerge(
            a: .dir(["a": .file([1])]),
            b: .dir(["b": .file([2])]),
            expect: .dir([
                    "a": .file([1]),
                    "b": .file([2])]))

        try checkMerge(
            a: .dir(["a": .dir([:])]),
            b: .dir(["a": .file([2])]),
            expect: .dir([
                    "a": .file([2])]))

        try checkMerge(
            a: .dir(["a": .file([1])]),
            b: .dir(["a": .dir([:])]),
            expect: .dir([
                    "a": .dir([:])]))

        try checkMerge(
            a: .dir(["a": .dir([
                            "aa": .file([1])
                        ])
                ]),
            b: .dir(["a": .dir([
                            "ab": .file([2])
                        ])
                ]),
            expect: .dir([
                    "a": .dir([
                            "aa": .file([1]),
                            "ab": .file([2]),
                        ])
                ]))
    }

    func testMergeAtPath() throws {
        try checkMerge(
            a: .dir(["a": .file([1])]),
            b: .dir(["b": .file([2])]),
            at: AbsolutePath("/"),
            expect: .dir([
                    "a": .file([1]),
                    "b": .file([2])]))

        try checkMerge(
            a: .dir(["a": .file([1])]),
            b: .dir(["b": .file([2])]),
            at: AbsolutePath("/b"),
            expect: .dir([
                    "a": .file([1]),
                    "b": .dir([
                            "b": .file([2])
                        ])]))

        try checkMerge(
            a: .dir(["a": .file([1])]),
            b: .dir(["b": .file([2])]),
            at: AbsolutePath("/a"),
            expect: .dir([
                    "a": .dir([
                            "b": .file([2])
                        ])]))
    }

    func testMergeMultiple() throws {
        // Basic case.
        try checkMerge(
            trees: [
                .dir(["a": .file([1])]),
                .dir(["b": .file([2])]),
                .dir(["c": .file([3])])],
            expect: .dir([
                    "a": .file([1]),
                    "b": .file([2]),
                    "c": .file([3])]))

        // Any non-directory overrides everything else.
        try checkMerge(
            trees: [
                .dir(["a": .dir(["a": .file([2])])]),
                .dir(["a": .file([1])]),
                .dir([:]), // empty dir, just to make things more tricky
            ],
            expect: .dir([
                    "a": .file([1])]))

        // Check handling of identical directories.
        try checkMerge(
            trees: [
                .dir(["a": .dir(["b": .file([2])])]), // these two ...
                .dir(["a": .dir(["b": .file([2])])]), // intentionally the same.
            ],
            expect: .dir([
                    "a": .dir([
                            "b": .file([2])])]))

        // Check conflicts in a subdirectory.
        try checkMerge(
            trees: [
                .dir(["a": .dir(["b": .file([3])])]),
                .dir(["a": .dir(["b": .file([2])])]),
                .dir(["a": .dir(["a": .file([1])])]),
            ],
            expect: .dir([
                    "a": .dir([
                            "a": .file([1]),
                            "b": .file([2])])]))
        try checkMerge(
            trees: [
                .dir(["a": .dir(["a": .file([1])])]),
                .dir(["a": .dir(["b": .file([2])])]),
                .dir(["a": .dir(["b": .file([3])])]),
            ],
            expect: .dir([
                    "a": .dir([
                            "a": .file([1]),
                            "b": .file([3])])]))
    }

    func testRemove() throws {
        let db = LLBInMemoryCASDatabase(group: group)
        let originalDeclTree: LLBDeclFileTree = .dir([
            "file1": .file([1]),
            "file2": .file([2]),
            "dir1": .dir([
                "file11": .file([1]),
                "file12": .file([2])
            ]),
            "dir2": .dir([
                "file21": .file([1]),
                "file22": .file([2]),
                "dir21": .dir([
                    "file211": .file([1]),
                    "file212": .file([2])
                ])
            ])
        ])
        let originalTree = try LLBCASFSClient(db).storeDir(originalDeclTree).wait()
        var modifiedTree: LLBCASFileTree?

        let returnCheckedPath = { (tree: LLBCASFileTree, path: String) in
            try tree.lookup(path: AbsolutePath(path), in: db).wait()
        }
        let returnRemoveResult = { (tree: LLBCASFileTree, path: String) in
            modifiedTree = try tree.remove(path: AbsolutePath(path), in: db).wait()
        }

        // deletion of existing file
        XCTAssertNotNil(try returnRemoveResult(originalTree, "/file1"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/file1"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/file2"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/file3"))

        // deletion of non-existing file
        XCTAssertNotNil(try returnRemoveResult(originalTree, "/file3"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/file1"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/file2"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/file3"))

        // deletion of directory (with subdirectories)
        XCTAssertNotNil(try returnRemoveResult(originalTree, "/dir1"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/file1"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/dir1"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/dir2"))

        // deletion of third level file
        XCTAssertNotNil(try returnRemoveResult(originalTree, "/dir2/dir21/file211"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/file1"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/dir2/dir21/file211"))
        XCTAssertNotNil(try returnCheckedPath(modifiedTree!, "/dir2/dir21/file212"))

        // deletion of non-existing file under existing subpath
        XCTAssertThrowsError(try returnRemoveResult(originalTree, "/dir1/file11/file111"))

        // deletion of root
        XCTAssertNotNil(try returnRemoveResult(originalTree, "/"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/dir1"))
        XCTAssertNil(try returnCheckedPath(modifiedTree!, "/file1"))
    }

    func testReparse() throws {
        let db = LLBInMemoryCASDatabase(group: group)
        let f1: LLBDeclFileTree = .file(Array(repeating: 1, count: 98))
        let f2: LLBDeclFileTree = .file(Array(repeating: 1, count: 99))
        let f1Id = try LLBCASFSClient(db).storeFile(f1).wait().asDirectoryEntry(filename: "").id
        XCTAssertEqual(try LLBCASFSClient(db).load(f1Id).wait().size(), 98)
        let f2Id = try LLBCASFSClient(db).storeFile(f2).wait().asDirectoryEntry(filename: "").id
        XCTAssertEqual(try LLBCASFSClient(db).load(f2Id).wait().size(), 99)
    }
    private func checkLookupPath(of path: AbsolutePath, in declTree: LLBDeclFileTree, is expected: (id: LLBDataID, info: LLBDirectoryEntry)?, file: StaticString = #file, line: UInt = #line) throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let tree = try LLBCASFSClient(db).storeDir(declTree).wait()
        let result = try tree.lookup(path: path, in: db).wait()
        XCTAssertEqual(result?.id, expected?.id)
        XCTAssertEqual(result?.info, expected?.info)
    }

    private func checkMerge(
        a: LLBDeclFileTree, b: LLBDeclFileTree, at path: AbsolutePath? = nil,
        expect expected: LLBDeclFileTree,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let aTree = try LLBCASFSClient(db).storeDir(a).wait()
        let bTree = try LLBCASFSClient(db).storeDir(b).wait()
        let merged: LLBCASFileTree
        if let path = path {
            merged = try aTree.merge(with: bTree, in: db, at: path).wait()
        } else {
            merged = try aTree.merge(with: bTree, in: db).wait()
        }
        let expectedTree = try LLBCASFSClient(db).storeDir(expected).wait()
        XCTAssertEqual(merged.id, expectedTree.id, file: (file), line: line)

        // These are redundant with above, but helps diagnoses.
        XCTAssertEqual(merged.files, expectedTree.files, file: (file), line: line)
        XCTAssertEqual(merged.object.refs, expectedTree.object.refs, file: (file), line: line)
    }

    private func checkMerge(
        trees declTrees: [LLBDeclFileTree],
        expect expected: LLBDeclFileTree,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let trees = try declTrees.map{ try LLBCASFSClient(db).storeDir($0).wait() }
        let merged = try LLBCASFileTree.merge(trees: trees, in: db).wait()
        let expectedTree = try LLBCASFSClient(db).storeDir(expected).wait()
        XCTAssertEqual(merged.id, expectedTree.id, file: (file), line: line)

        // These are redundant with above, but helps diagnoses.
        XCTAssertEqual(merged.files, expectedTree.files, file: (file), line: line)
        XCTAssertEqual(merged.object.refs, expectedTree.object.refs, file: (file), line: line)

        // Also check equivalence with pairwise merge.
        if !trees.isEmpty {
            let pairwiseMerged = try trees.reduce(LLBCASFileTree.create(files: [], in: db).wait()) {
                try $0.merge(with: $1, in: db).wait()
            }
            XCTAssertEqual(pairwiseMerged.id, expectedTree.id, file: (file), line: line)
            XCTAssertEqual(pairwiseMerged.files, expectedTree.files, file: (file), line: line)
            XCTAssertEqual(pairwiseMerged.object.refs, expectedTree.object.refs, file: (file), line: line)
        }
    }}
