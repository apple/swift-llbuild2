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
import llbuild2Testing
import FXAsyncSupport
import XCTest

class LinkedListStreamTests: XCTestCase {
    let group = FXMakeDefaultDispatchGroup()

    func testSingleLine() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        var writer = LLBLinkedListStreamWriter(db)

        writer.append(data: FXByteBuffer(string: "hello, world!"), ctx)

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        var contentRead = false
        try reader.read(id: latestID, ctx) { (channel, data) -> Bool in
            let stringData = String(decoding: Data(data), as: UTF8.self)
            XCTAssertEqual(stringData, "hello, world!")
            contentRead = true
            return true
        }.wait()

        XCTAssertTrue(contentRead)
    }

    func testStreamSingleChannel() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let writeStream = Array(0...20).map { "Stream line \($0)" }

        var writer = LLBLinkedListStreamWriter(db)

        for block in writeStream {
            writer.append(data: FXByteBuffer(string: block), ctx)
        }

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        var readStream = [String]()

        try reader.read(id: latestID, ctx) { (channel, data) -> Bool in
            let block = String(decoding: Data(data), as: UTF8.self)
            readStream.append(block)
            return true
        }.wait()

        XCTAssertEqual(readStream, writeStream)
    }

    func testStreamMultiChannel() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let writeStream: [(UInt8, String)] = Array(0...20).map { ($0 % 4, "Stream line \($0)") }

        var writer = LLBLinkedListStreamWriter(db)

        for (channel, block) in writeStream {
            writer.append(data: FXByteBuffer(string: block), channel: channel, ctx)
        }

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        var readStream = [String]()

        try reader.read(id: latestID, channels: [0, 1], ctx) { (channel, data) -> Bool in
            let block = String(decoding: Data(data), as: UTF8.self)
            readStream.append(block)
            return true
        }.wait()

        let filteredWriteStream = writeStream.filter { $0.0 <= 1 }.map { $0.1 }

        XCTAssertEqual(readStream, filteredWriteStream)
    }

    func testStreamAggregateSize() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let writeStream: [(UInt8, String)] = Array(0...1).map { ($0 % 2, "Stream line \($0)") }

        var writer = LLBLinkedListStreamWriter(db)

        for (channel, block) in writeStream {
            writer.append(data: FXByteBuffer(string: block), channel: channel, ctx)
        }

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        let node = try FXCASFSClient(db).load(latestID, ctx).wait()

        var readLength: Int = 0
        try reader.read(id: latestID, ctx) { (channel, data) -> Bool in
            readLength += data.count
            return true
        }.wait()

        XCTAssertEqual(node.size(), readLength)
    }

    func testStreamReadLimit() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let writeStream = Array(0...20).map { "Stream line \($0)" }

        var writer = LLBLinkedListStreamWriter(db)

        for block in writeStream {
            writer.append(data: FXByteBuffer(string: block), ctx)
        }

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        var readStream = [String]()

        var stopped = false
        try reader.read(id: latestID, ctx) { (channel, data) -> Bool in
            // Read only 5 elements
            if readStream.count == 5 {
                stopped = true
                return false
            }
            guard !stopped else {
                XCTFail("Requested to stop but kept receiving data")
                return false
            }

            let block = String(decoding: Data(data), as: UTF8.self)
            readStream.append(block)
            return true
        }.wait()

        XCTAssertEqual(readStream, Array(writeStream.prefix(5)))
    }

    func testStreamFromPreviousState() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let writeStream = Array(0...20).map { "Stream line \($0)" }

        var writer = LLBLinkedListStreamWriter(db)

        for block in writeStream {
            writer.append(data: FXByteBuffer(string: block), ctx)
        }

        let startMarker = try writer.latestID!.wait()

        let writeStream2 = Array(21...40).map { "Stream line \($0)" }

        for block in writeStream2 {
            writer.append(data: FXByteBuffer(string: block), ctx)
        }

        let reader = FXCASStreamReader(db)

        let latestID = try writer.latestID!.wait()

        var readStream = [String]()

        try reader.read(id: latestID, lastReadID: startMarker, ctx) { (channel, data) -> Bool in
            let block = String(decoding: Data(data), as: UTF8.self)
            readStream.append(block)
            return true
        }.wait()

        XCTAssertEqual(readStream, writeStream2)
    }
}
