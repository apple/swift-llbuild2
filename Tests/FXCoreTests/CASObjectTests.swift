// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import FXCore
import FXAsyncSupport
import TSCUtility
import XCTest

final class CASObjectTests: XCTestCase {
    // MARK: - FXCASObject Initialization

    func testInitWithByteBuffer() {
        let data = FXByteBuffer.withBytes([1, 2, 3])
        let obj = FXCASObject(refs: [], data: data)
        XCTAssertEqual(obj.refs, [])
        XCTAssertEqual(obj.data, data)
        XCTAssertEqual(obj.size, 3)
    }

    func testInitWithByteBufferView() {
        let data = FXByteBuffer.withBytes([10, 20, 30])
        let view = data.readableBytesView
        let obj = FXCASObject(refs: [], data: view)
        XCTAssertEqual(obj.size, 3)
        XCTAssertEqual(Array(buffer: obj.data), [10, 20, 30])
    }

    func testInitWithRefs() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try! db.put(data: FXByteBuffer.withBytes([1]), ctx).wait()

        let obj = FXCASObject(refs: [id], data: FXByteBuffer.withBytes([42]))
        XCTAssertEqual(obj.refs, [id])
        XCTAssertEqual(obj.size, 1)
    }

    func testEmptyObject() {
        let obj = FXCASObject(refs: [], data: FXByteBuffer())
        XCTAssertEqual(obj.refs, [])
        XCTAssertEqual(obj.size, 0)
    }

    // MARK: - Equatable

    func testEquality() {
        let obj1 = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2]))
        let obj2 = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2]))
        let obj3 = FXCASObject(refs: [], data: FXByteBuffer.withBytes([3, 4]))
        XCTAssertEqual(obj1, obj2)
        XCTAssertNotEqual(obj1, obj3)
    }

    // MARK: - Serialization

    func testDataRoundTrip() throws {
        let original = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2, 3, 4, 5]))
        let serialized = try original.toData()
        let restored = try FXCASObject(rawBytes: serialized)
        XCTAssertEqual(original, restored)
    }

    func testDataRoundTripWithRefs() throws {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let refID = try db.put(data: FXByteBuffer.withBytes([99]), ctx).wait()

        let original = FXCASObject(refs: [refID], data: FXByteBuffer.withBytes([10, 20]))
        let serialized = try original.toData()
        let restored = try FXCASObject(rawBytes: serialized)
        XCTAssertEqual(original.refs, restored.refs)
        XCTAssertEqual(original.data, restored.data)
    }

    func testByteBufferSerializationRoundTrip() throws {
        let original = FXCASObject(refs: [], data: FXByteBuffer.withBytes([7, 8, 9]))
        let buffer = try original.toBytes()
        let restored = try FXCASObject(from: buffer)
        XCTAssertEqual(original, restored)
    }

    func testEmptyDataRoundTrip() throws {
        let original = FXCASObject(refs: [], data: FXByteBuffer())
        let serialized = try original.toData()
        let restored = try FXCASObject(rawBytes: serialized)
        XCTAssertEqual(original.size, restored.size)
        XCTAssertEqual(original.refs, restored.refs)
    }
}

final class CASObjectDatabaseConvenienceTests: XCTestCase {
    let group = FXMakeDefaultDispatchGroup()

    func testPutAndGetObject() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let obj = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2, 3]))

        let id = try db.put(obj, ctx).wait()
        let retrieved = try db.get(id, ctx).wait()!
        XCTAssertEqual(retrieved, obj)
    }

    func testIdentifyObject() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let obj = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2, 3]))

        let identifiedID = try db.identify(obj, ctx).wait()
        let putID = try db.put(obj, ctx).wait()
        XCTAssertEqual(identifiedID, putID)
    }

    func testPutWithByteBufferView() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let buf = FXByteBuffer.withBytes([5, 6, 7])
        let view = buf.readableBytesView

        let id = try db.put(refs: [], data: view, ctx).wait()
        let obj = try db.get(id, ctx).wait()!
        XCTAssertEqual(Array(buffer: obj.data), [5, 6, 7])
    }

    func testPutDataOnly() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()

        let id = try db.put(data: FXByteBuffer.withBytes([42]), ctx).wait()
        let obj = try db.get(id, ctx).wait()!
        XCTAssertEqual(obj.refs, [])
        XCTAssertEqual(Array(buffer: obj.data), [42])
    }

    func testIdentifyWithByteBufferView() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let buf = FXByteBuffer.withBytes([1, 2])
        let view = buf.readableBytesView

        let id1 = try db.identify(refs: [], data: view, ctx).wait()
        let id2 = try db.put(refs: [], data: buf, ctx).wait()
        XCTAssertEqual(id1, id2)
    }

    func testPutKnownIDWithObject() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let obj = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2, 3]))
        let knownID = try db.identify(obj, ctx).wait()

        let returnedID = try db.put(knownID: knownID, object: obj, ctx).wait()
        XCTAssertEqual(returnedID, knownID)
        let retrieved = try db.get(returnedID, ctx).wait()!
        XCTAssertEqual(retrieved, obj)
    }

    func testPutKnownIDWithByteBufferView() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let buf = FXByteBuffer.withBytes([9, 8, 7])
        let knownID = try db.identify(refs: [], data: buf, ctx).wait()

        let returnedID = try db.put(knownID: knownID, refs: [], data: buf.readableBytesView, ctx).wait()
        XCTAssertEqual(returnedID, knownID)
    }

    func testSupportedFeatures() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let features = try db.supportedFeatures().wait()
        XCTAssertTrue(features.preservesIDs)
    }
}

final class CASFeaturesTests: XCTestCase {
    func testDefaultPreservesIDs() {
        let features = FXCASFeatures()
        XCTAssertTrue(features.preservesIDs)
    }

    func testNonPreservingFeatures() {
        let features = FXCASFeatures(preservesIDs: false)
        XCTAssertFalse(features.preservesIDs)
    }

    func testCodableRoundTrip() throws {
        let original = FXCASFeatures(preservesIDs: false)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FXCASFeatures.self, from: data)
        XCTAssertEqual(original.preservesIDs, restored.preservesIDs)
    }
}

final class ContextDatabaseTests: XCTestCase {
    func testContextWithGroup() {
        let group = FXMakeDefaultDispatchGroup()
        let ctx = Context.with(group)
        // Verify we can use the group from context
        let promise = ctx.group.next().makePromise(of: Int.self)
        promise.succeed(42)
        XCTAssertEqual(try promise.futureResult.wait(), 42)
    }

    func testContextGroupSetGet() {
        let group = FXMakeDefaultDispatchGroup()
        var ctx = Context()
        ctx.group = group
        let promise = ctx.group.next().makePromise(of: Int.self)
        promise.succeed(1)
        XCTAssertEqual(try promise.futureResult.wait(), 1)
    }
}

final class ByteBufferExtensionTests: XCTestCase {
    func testWithBytesFromArray() {
        let buf = FXByteBuffer.withBytes([1, 2, 3, 4])
        XCTAssertEqual(buf.readableBytes, 4)
        XCTAssertEqual(Array(buffer: buf), [1, 2, 3, 4])
    }

    func testWithBytesFromData() {
        let data = Data([10, 20, 30])
        let buf = FXByteBuffer.withBytes(data)
        XCTAssertEqual(buf.readableBytes, 3)
        XCTAssertEqual(Array(buffer: buf), [10, 20, 30])
    }

    func testWithBytesFromArraySlice() {
        let arr: [UInt8] = [1, 2, 3, 4, 5]
        let slice = arr[1..<4]
        let buf = FXByteBuffer.withBytes(slice)
        XCTAssertEqual(buf.readableBytes, 3)
        XCTAssertEqual(Array(buffer: buf), [2, 3, 4])
    }

    func testWithBytesEmpty() {
        let buf = FXByteBuffer.withBytes([UInt8]())
        XCTAssertEqual(buf.readableBytes, 0)
    }

    func testReserveWriteCapacity() {
        var buf = FXByteBuffer.withBytes([1, 2])
        buf.reserveWriteCapacity(100)
        // Should not crash and buffer should still have original data
        XCTAssertEqual(buf.readableBytes, 2)
    }

    func testUnsafeWrite() {
        var buf = FXByteBufferAllocator().buffer(capacity: 10)
        buf.reserveWriteCapacity(4)
        let result = buf.unsafeWrite { ptr -> (wrote: Int, String) in
            ptr[0] = 0xAA
            ptr[1] = 0xBB
            return (wrote: 2, "done")
        }
        XCTAssertEqual(result, "done")
        XCTAssertEqual(buf.readableBytes, 2)
    }
}

final class FXPromiseTests: XCTestCase {
    func testFulfillSuccess() throws {
        let group = FXMakeDefaultDispatchGroup()
        let promise = group.next().makePromise(of: Int.self)
        promise.fulfill { 42 }
        XCTAssertEqual(try promise.futureResult.wait(), 42)
    }

    func testFulfillFailure() {
        let group = FXMakeDefaultDispatchGroup()
        let promise = group.next().makePromise(of: Int.self)
        struct TestError: Error {}
        promise.fulfill { throw TestError() }
        XCTAssertThrowsError(try promise.futureResult.wait())
    }
}

final class FXFutureUnwrapTests: XCTestCase {
    func testUnwrapOptionalSuccess() throws {
        let group = FXMakeDefaultDispatchGroup()
        let el = group.next()
        let future: FXFuture<Int?> = el.makeSucceededFuture(42)
        let unwrapped: FXFuture<Int> = future.fx_unwrapOptional(orError: FXSerializableError.unknownError("nil"))
        XCTAssertEqual(try unwrapped.wait(), 42)
    }

    func testUnwrapOptionalNil() {
        let group = FXMakeDefaultDispatchGroup()
        let el = group.next()
        let future: FXFuture<Int?> = el.makeSucceededFuture(nil)
        let unwrapped: FXFuture<Int> = future.fx_unwrapOptional(orError: FXSerializableError.unknownError("was nil"))
        XCTAssertThrowsError(try unwrapped.wait())
    }

    func testUnwrapOptionalStringError() {
        let group = FXMakeDefaultDispatchGroup()
        let el = group.next()
        let future: FXFuture<String?> = el.makeSucceededFuture(nil)
        let unwrapped: FXFuture<String> = future.fx_unwrapOptional(orStringError: "missing value")
        XCTAssertThrowsError(try unwrapped.wait())
    }

    func testUnwrapOptionalStringErrorSuccess() throws {
        let group = FXMakeDefaultDispatchGroup()
        let el = group.next()
        let future: FXFuture<String?> = el.makeSucceededFuture("hello")
        let unwrapped: FXFuture<String> = future.fx_unwrapOptional(orStringError: "missing value")
        XCTAssertEqual(try unwrapped.wait(), "hello")
    }
}
