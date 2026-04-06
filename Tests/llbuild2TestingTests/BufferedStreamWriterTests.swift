// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import TSCBasic
import FXAsyncSupport
import TSCUtility
import FXAsyncSupport
import FXCore
import FXAsyncSupport
import llbuild2Testing
import FXAsyncSupport
import XCTest

class BufferedStreamWriterTests: XCTestCase {
    let group = FXMakeDefaultDispatchGroup()

    func testBasics() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let allocator = FXByteBufferAllocator()

        let writer = LLBBufferedStreamWriter(db, bufferSize: 32)

        var buffer = allocator.buffer(capacity: 128)
        buffer.writeRepeatingByte(65, count: 16)

        writer.write(data: buffer, channel: 0)

        // Nil because it hasn't buffered out yet.
        XCTAssertNil(writer.latestID)

        buffer.clear()
        buffer.writeRepeatingByte(65, count: 16)
        writer.write(data: buffer, channel: 0)

        // Now there should be an ID because we've reached the buffer size
        let dataID = try XCTUnwrap(writer.latestID).wait()

        let reader = FXCASStreamReader(db)

        var readBuffer = allocator.buffer(capacity: 32)

        var timesCalled = 0
        try reader.read(id: dataID, ctx) { (channel, data) -> Bool in
            print(data.count)
            readBuffer.writeBytes(data)
            timesCalled += 1
            return true
        }.wait()

        XCTAssertEqual(timesCalled, 1)
        XCTAssertEqual(
            Data(readBuffer.readableBytesView), Data(FXByteBufferView(repeating: 65, count: 32)))
    }

    func testDifferentChannels() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let allocator = FXByteBufferAllocator()

        let writer = LLBBufferedStreamWriter(db, bufferSize: 32)

        var buffer = allocator.buffer(capacity: 128)
        buffer.writeRepeatingByte(65, count: 16)

        writer.write(data: buffer, channel: 0)

        // Nil because it hasn't buffered out yet.
        XCTAssertNil(writer.latestID)

        buffer.clear()
        buffer.writeRepeatingByte(65, count: 16)
        writer.write(data: buffer, channel: 1)

        // Flush to send the remaining data.
        writer.flush()

        // Now there should be an ID because we've reached the buffer size
        let dataID = try XCTUnwrap(writer.latestID).wait()

        let reader = FXCASStreamReader(db)

        var readBuffer = allocator.buffer(capacity: 32)

        var timesCalled = 0
        var channelsRead = Set<UInt8>()
        try reader.read(id: dataID, ctx) { (channel, data) -> Bool in
            readBuffer.writeBytes(data)
            channelsRead.insert(channel)
            timesCalled += 1
            return true
        }.wait()

        XCTAssertEqual(timesCalled, 2)
        XCTAssertEqual(
            Data(readBuffer.readableBytesView), Data(FXByteBufferView(repeating: 65, count: 32)))
        XCTAssertEqual(channelsRead, [0, 1])
    }
}
