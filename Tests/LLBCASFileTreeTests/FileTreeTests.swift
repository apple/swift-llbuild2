// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import TSCBasic

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

}
