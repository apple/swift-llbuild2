// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest
import Dispatch

import NIO
import TSCBasic

import llbuild2
import LLBUtil


class FileBackedCASDatabaseTests: XCTestCase {

    var group: LLBFuturesDispatchGroup!
    var threadPool: NIOThreadPool!
    var fileIO: NonBlockingFileIO!

    override func setUp() {
        super.setUp()
        group = LLBMakeDefaultDispatchGroup()
        threadPool = NIOThreadPool(numberOfThreads: 6)
        threadPool.start()
        fileIO = NonBlockingFileIO(threadPool: threadPool)
    }

    override func tearDown() {
        super.tearDown()
        try? group.syncShutdownGracefully()
        try? threadPool.syncShutdownGracefully()
        group = nil
    }

    /// ${TMPDIR} or just "/tmp", expressed as AbsolutePath
    private var temporaryPath: AbsolutePath {
        return AbsolutePath(ProcessInfo.processInfo.environment["TMPDIR", default: "/tmp"])
    }


    func testBasics() throws {
        try withTemporaryDirectory(dir: temporaryPath, prefix: "LLBUtilTests" + #function, removeTreeOnDeinit: true) { tmpDir in
            let db = LLBFileBackedCASDatabase(group: group, threadPool: threadPool, fileIO: fileIO, path: tmpDir)

            let id1 = try db.put(data: LLBByteBuffer.withBytes([1, 2, 3])).wait()
            let obj1 = try db.get(id1).wait()!
            XCTAssertEqual(id1, LLBDataID(string: "0~sXfsG_Jt-ztwENRz5tRHE7KbdluZxuYOy_rnQt5JZUM="))
            XCTAssertEqual(obj1.size, 3)
            XCTAssertEqual(obj1.refs, [])
            XCTAssertEqual(obj1.data, LLBByteBuffer.withBytes([1, 2, 3]))
            XCTAssertEqual(try db.contains(id1).wait(), true)

            let id2 = try db.put(refs: [id1], data: LLBByteBuffer.withBytes([4, 5, 6])).wait()
            let obj2 = try db.get(id2).wait()!
            XCTAssertEqual(id2, LLBDataID(string: "0~udZrZzFHJr8uovWT5dOWtKz95ZqKi-vBkpiH0mJfjM4="))
            XCTAssertEqual(obj2.size, 3)
            XCTAssertEqual(obj2.refs, [id1])
            XCTAssertEqual(obj2.data, LLBByteBuffer.withBytes([4, 5, 6]))

            // Check contains on a missing object.
            let missingID = try LLBInMemoryCASDatabase(group: group).identify(data: LLBByteBuffer.withBytes([])).wait()
            XCTAssertEqual(try db.contains(missingID).wait(), false)
        }
    }

    func testPutStressTest() throws {
        try withTemporaryDirectory(dir: temporaryPath, prefix: "LLBUtilTests" + #function, removeTreeOnDeinit: true) { tmpDir in
            let db = LLBFileBackedCASDatabase(group: group, threadPool: threadPool, fileIO: fileIO, path: tmpDir)
            let queue = DispatchQueue(label: "sync")

            // Insert one object.
            let id1 = try db.put(data: LLBByteBuffer.withBytes([1, 2, 3])).wait()

            // Insert a bunch of objects concurrently.
            //
            // We take care here to do this in a way that no references to the
            // object data is held (other than in the database).
            let allocator = LLBByteBufferAllocator()
            func makeData(i: Int, objectSize: Int = 16) -> LLBByteBuffer {
                var buffer = allocator.buffer(capacity: objectSize)
                for j in 0 ..< objectSize {
                    buffer.writeInteger(UInt8((i + j) & 0xFF))
                }
                return buffer
            }
            let numObjects = 100
            var objects = [LLBDataID?](repeating: nil, count: numObjects)
            DispatchQueue.concurrentPerform(iterations: numObjects) { i in
                let id = { try! db.put(refs: [id1], data: makeData(i: i)).wait() }()
                queue.sync {
                    objects[i] = id
                }
            }

            for i in 0 ..< numObjects {
                guard let result = try db.get(objects[i]!).wait() else {
                    XCTFail("missing expected object")
                    return
                }
                XCTAssertEqual(result.refs, [id1])
                XCTAssertEqual(result.data, makeData(i: i))
            }
        }
    }

}
