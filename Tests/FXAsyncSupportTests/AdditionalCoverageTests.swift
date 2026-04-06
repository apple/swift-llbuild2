// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Atomics
import FXAsyncSupport
import FXCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import TSCBasic
import XCTest

// MARK: - CancelHandlersChain Tests

final class CancelHandlersChainTests: XCTestCase {
    struct CountingHandler: LLBCancelProtocol {
        private let called = ManagedAtomic(0)
        private let lastReason = NIOLockedValueBox<String?>(nil)

        var timesCalled: Int {
            called.load(ordering: .relaxed)
        }

        var reason: String? {
            lastReason.withLockedValue { $0 }
        }

        func cancel(reason: String?) {
            called.wrappingIncrement(ordering: .relaxed)
            lastReason.withLockedValue { $0 = reason }
        }
    }

    func testBasicChainCancellation() {
        let h1 = CountingHandler()
        let h2 = CountingHandler()
        let chain = LLBCancelHandlersChain(h1, h2)

        chain.cancel(reason: "test")
        XCTAssertEqual(h1.timesCalled, 1)
        XCTAssertEqual(h2.timesCalled, 1)
        XCTAssertEqual(h1.reason, "test")
    }

    func testChainWithNilHandlers() {
        let chain = LLBCancelHandlersChain(nil, nil)
        // Should not crash
        chain.cancel(reason: "test")
    }

    func testChainWithOneHandler() {
        let h1 = CountingHandler()
        let chain = LLBCancelHandlersChain(h1, nil)
        chain.cancel(reason: "solo")
        XCTAssertEqual(h1.timesCalled, 1)
        XCTAssertEqual(h1.reason, "solo")
    }

    func testAddHandlerToChain() {
        let h1 = CountingHandler()
        let h2 = CountingHandler()
        let h3 = CountingHandler()
        let canceller = LLBCanceller()
        let chain = LLBCancelHandlersChain(h1, h2)
        canceller.set(handler: chain)

        chain.add(handler: h3, for: canceller)
        chain.cancel(reason: "all")

        XCTAssertEqual(h3.timesCalled, 1)
    }

    func testAddHandlerAfterCancellation() {
        let h1 = CountingHandler()
        let h2 = CountingHandler()
        let canceller = LLBCanceller()
        let chain = LLBCancelHandlersChain()
        canceller.set(handler: chain)

        canceller.cancel(reason: "early")

        chain.add(handler: h1, for: canceller)
        XCTAssertEqual(h1.timesCalled, 1)

        chain.add(handler: h2, for: canceller)
        XCTAssertEqual(h2.timesCalled, 1)
    }

    func testDoubleCancelOnChain() {
        let h1 = CountingHandler()
        let chain = LLBCancelHandlersChain(h1, nil)
        chain.cancel(reason: "first")
        chain.cancel(reason: "second")
        // Handlers are cleared on first cancel, so only called once
        XCTAssertEqual(h1.timesCalled, 1)
    }

    func testChainGrowsBeyondTwo() {
        let h1 = CountingHandler()
        let h2 = CountingHandler()
        let h3 = CountingHandler()
        let canceller = LLBCanceller()
        let chain = LLBCancelHandlersChain(h1, h2)
        canceller.set(handler: chain)

        // Adding a third handler causes internal restructuring
        chain.add(handler: h3, for: canceller)
        chain.cancel(reason: "all three")

        XCTAssertEqual(h3.timesCalled, 1)
        // h1 and h2 are now in a sub-chain
    }
}

// MARK: - Canceller Additional Tests

final class CancellerAdditionalTests: XCTestCase {
    struct SimpleHandler: LLBCancelProtocol {
        private let called = ManagedAtomic(false)
        var wasCalled: Bool { called.load(ordering: .relaxed) }
        func cancel(reason: String?) {
            called.store(true, ordering: .relaxed)
        }
    }

    func testIsCancelledProperty() {
        let canceller = LLBCanceller()
        XCTAssertFalse(canceller.isCancelled)
        canceller.cancel(reason: "test")
        XCTAssertTrue(canceller.isCancelled)
    }

    func testCancelReasonProperty() {
        let canceller = LLBCanceller()
        XCTAssertNil(canceller.cancelReason)
        canceller.cancel(reason: "specific reason")
        XCTAssertEqual(canceller.cancelReason, "specific reason")
    }

    func testCancelWithNilReason() {
        let canceller = LLBCanceller()
        canceller.cancel(reason: nil)
        XCTAssertTrue(canceller.isCancelled)
        XCTAssertEqual(canceller.cancelReason, "no reason given")
    }

    func testAbandonedCancellerNotCancelled() {
        let canceller = LLBCanceller()
        canceller.abandon()
        XCTAssertFalse(canceller.isCancelled)
        XCTAssertNil(canceller.cancelReason)
    }
}

// MARK: - FastData Tests

final class FastDataTests: XCTestCase {
    func testSliceFromArray() {
        let fd = LLBFastData([1, 2, 3, 4, 5])
        XCTAssertEqual(fd.count, 5)
        fd.withContiguousStorage { ptr in
            XCTAssertEqual(ptr[0], 1)
            XCTAssertEqual(ptr[4], 5)
        }
    }

    func testSliceFromArraySlice() {
        let arr: [UInt8] = [10, 20, 30, 40]
        let fd = LLBFastData(arr[1..<3])
        XCTAssertEqual(fd.count, 2)
        fd.withContiguousStorage { ptr in
            XCTAssertEqual(ptr[0], 20)
            XCTAssertEqual(ptr[1], 30)
        }
    }

    func testViewFromByteBuffer() {
        let buf = FXByteBuffer.withBytes([7, 8, 9])
        let fd = LLBFastData(buf)
        XCTAssertEqual(fd.count, 3)
        fd.withContiguousStorage { ptr in
            XCTAssertEqual(ptr[0], 7)
            XCTAssertEqual(ptr[2], 9)
        }
    }

    func testFromData() {
        let data = Data([100, 200])
        let fd = LLBFastData(data)
        XCTAssertEqual(fd.count, 2)
        fd.withContiguousStorage { ptr in
            XCTAssertEqual(ptr[0], 100)
            XCTAssertEqual(ptr[1], 200)
        }
    }

    func testPointerCase() {
        let bytes: [UInt8] = [1, 2, 3]
        bytes.withUnsafeBytes { rawBuf in
            let ptr = UnsafeRawBufferPointer(rawBuf)
            let fd = LLBFastData(ptr) { _ in }
            XCTAssertEqual(fd.count, 3)
            fd.withContiguousStorage { bufPtr in
                XCTAssertEqual(bufPtr[0], 1)
                XCTAssertEqual(bufPtr[2], 3)
            }
        }
    }

    func testEmptySlice() {
        let fd = LLBFastData([UInt8]())
        XCTAssertEqual(fd.count, 0)
    }

    func testEmptyByteBuffer() {
        let fd = LLBFastData(FXByteBuffer())
        XCTAssertEqual(fd.count, 0)
    }
}

// MARK: - FutureFileSystem Tests

final class FutureFileSystemTests: XCTestCase {
    var group: FXFuturesDispatchGroup!
    var fs: FXFutureFileSystem!
    var tempDir: String!

    override func setUp() {
        super.setUp()
        group = FXMakeDefaultDispatchGroup()
        fs = FXFutureFileSystem(group: group)
        tempDir = NSTemporaryDirectory()
    }

    override func tearDown() {
        super.tearDown()
        try? group.syncShutdownGracefully()
    }

    func testReadSmallFile() throws {
        // Create a temp file
        let path = (tempDir as NSString).appendingPathComponent("fx_test_small_\(UUID().uuidString)")
        let content = Data([1, 2, 3, 4, 5])
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try fs.readFileContents(try .init(validating: path)).wait()
        XCTAssertEqual(Array(result), [1, 2, 3, 4, 5])
    }

    func testReadFileContentsWithStat() throws {
        let path = (tempDir as NSString).appendingPathComponent("fx_test_stat_\(UUID().uuidString)")
        let content = Data([10, 20, 30])
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (bytes, stat) = try fs.readFileContentsWithStat(try .init(validating: path)).wait()
        XCTAssertEqual(Array(bytes), [10, 20, 30])
        XCTAssertEqual(Int(stat.st_size), 3)
    }

    func testGetFileInfo() throws {
        let path = (tempDir as NSString).appendingPathComponent("fx_test_info_\(UUID().uuidString)")
        let content = Data(repeating: 0xAA, count: 42)
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let stat = try fs.getFileInfo(try .init(validating: path)).wait()
        XCTAssertEqual(Int(stat.st_size), 42)
    }

    func testReadLargerFile() throws {
        let path = (tempDir as NSString).appendingPathComponent("fx_test_large_\(UUID().uuidString)")
        // Create a file > 8KB to exercise the full read path
        let content = Data(repeating: 0x42, count: 16 * 1024)
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try fs.readFileContents(try .init(validating: path)).wait()
        XCTAssertEqual(result.count, 16 * 1024)
        XCTAssertTrue(result.allSatisfy { $0 == 0x42 })
    }

    func testReadNonexistentFile() throws {
        let path = (tempDir as NSString).appendingPathComponent("fx_test_nonexistent_\(UUID().uuidString)")
        XCTAssertThrowsError(try fs.readFileContents(try .init(validating: path)).wait())
    }
}
