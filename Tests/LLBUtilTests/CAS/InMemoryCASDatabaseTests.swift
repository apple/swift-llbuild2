// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import XCTest

import Dispatch

import llbuild2
import LLBUtil

class InMemoryCASDatabaseTests: XCTestCase {
    let group = LLBMakeDefaultDispatchGroup()

    func testBasics() throws {
        let db = LLBInMemoryCASDatabase(group: group)

        let id1 = try db.put(data: LLBByteBuffer.withBytes([1, 2, 3])).wait()
        let obj1 = try db.get(id1).wait()!
        XCTAssertEqual(id1, LLBDataID(string: "0~sXfsG_Jt-ztwENRz5tRHE7KbdluZxuYOy_rnQt5JZUM="))
        XCTAssertEqual(obj1.size, 3)
        XCTAssertEqual(obj1.refs, [])
        XCTAssertEqual(obj1.data, LLBByteBuffer.withBytes([1, 2, 3]))

        let id2 = try db.put(refs: [id1], data: LLBByteBuffer.withBytes([4, 5, 6])).wait()
        let obj2 = try db.get(id2).wait()!
        XCTAssertEqual(id2, LLBDataID(string: "0~udZrZzFHJr8uovWT5dOWtKz95ZqKi-vBkpiH0mJfjM4="))
        XCTAssertEqual(obj2.size, 3)
        XCTAssertEqual(obj2.refs, [id1])
        XCTAssertEqual(obj2.data.getBytes(at: 0, length: obj2.data.readableBytes), [4, 5, 6])
        XCTAssertEqual(try db.contains(id1).wait(), true)

        // Check contains on a missing object.
        let missingID = try LLBInMemoryCASDatabase(group: group).put(data: LLBByteBuffer.withBytes([])).wait()
        XCTAssertEqual(try db.contains(missingID).wait(), false)
    }

    func testPutStressTest() throws {
        let db = LLBInMemoryCASDatabase(group: group)
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
