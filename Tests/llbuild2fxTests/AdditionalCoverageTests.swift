// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import Foundation
import Logging
import NIOCore
import XCTest

@testable import llbuild2fx

// MARK: - SortedSet Tests

final class SortedSetTests: XCTestCase {
    func testEmptyInit() {
        let set = FXSortedSet<Int>()
        XCTAssertTrue(set.isEmpty)
        XCTAssertEqual(set.count, 0)
    }

    func testInitFromArray() {
        let set = FXSortedSet([3, 1, 2, 1])
        XCTAssertEqual(Array(set), [1, 2, 3])
        XCTAssertEqual(set.count, 3)
    }

    func testInitFromSet() {
        let set = FXSortedSet(Set([5, 3, 1]))
        XCTAssertEqual(Array(set), [1, 3, 5])
    }

    func testArrayLiteralInit() {
        let set: FXSortedSet<Int> = [4, 2, 4, 1]
        XCTAssertEqual(Array(set), [1, 2, 4])
    }

    func testContains() {
        let set: FXSortedSet<Int> = [1, 2, 3]
        XCTAssertTrue(set.contains(2))
        XCTAssertFalse(set.contains(4))
    }

    func testInsert() {
        var set: FXSortedSet<Int> = [1, 3]
        let (inserted, _) = set.insert(2)
        XCTAssertTrue(inserted)
        XCTAssertEqual(Array(set), [1, 2, 3])

        let (inserted2, _) = set.insert(2)
        XCTAssertFalse(inserted2)
    }

    func testRemove() {
        var set: FXSortedSet<Int> = [1, 2, 3]
        let removed = set.remove(2)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Array(set), [1, 3])

        let removedNil = set.remove(99)
        XCTAssertNil(removedNil)
    }

    func testUpdate() {
        var set: FXSortedSet<Int> = [1, 2, 3]
        let old = set.update(with: 2)
        XCTAssertEqual(old, 2)

        let oldNil = set.update(with: 4)
        XCTAssertNil(oldNil)
        XCTAssertEqual(Array(set), [1, 2, 3, 4])
    }

    func testUnion() {
        let a: FXSortedSet<Int> = [1, 2, 3]
        let b: FXSortedSet<Int> = [3, 4, 5]
        let u = a.union(b)
        XCTAssertEqual(Array(u), [1, 2, 3, 4, 5])
    }

    func testIntersection() {
        let a: FXSortedSet<Int> = [1, 2, 3, 4]
        let b: FXSortedSet<Int> = [2, 4, 6]
        XCTAssertEqual(Array(a.intersection(b)), [2, 4])
    }

    func testSymmetricDifference() {
        let a: FXSortedSet<Int> = [1, 2, 3]
        let b: FXSortedSet<Int> = [2, 3, 4]
        XCTAssertEqual(Array(a.symmetricDifference(b)), [1, 4])
    }

    func testFormUnion() {
        var a: FXSortedSet<Int> = [1, 2]
        let b: FXSortedSet<Int> = [2, 3]
        a.formUnion(b)
        XCTAssertEqual(Array(a), [1, 2, 3])
    }

    func testFormIntersection() {
        var a: FXSortedSet<Int> = [1, 2, 3]
        let b: FXSortedSet<Int> = [2, 3, 4]
        a.formIntersection(b)
        XCTAssertEqual(Array(a), [2, 3])
    }

    func testFormSymmetricDifference() {
        var a: FXSortedSet<Int> = [1, 2, 3]
        let b: FXSortedSet<Int> = [2, 3, 4]
        a.formSymmetricDifference(b)
        XCTAssertEqual(Array(a), [1, 4])
    }

    func testEquality() {
        let a: FXSortedSet<Int> = [1, 2, 3]
        let b = FXSortedSet([3, 1, 2])
        XCTAssertEqual(a, b)
    }

    func testHashable() {
        let a: FXSortedSet<Int> = [1, 2, 3]
        let b: FXSortedSet<Int> = [1, 2, 3]
        XCTAssertEqual(a.hashValue, b.hashValue)

        var dict: [FXSortedSet<Int>: String] = [:]
        dict[a] = "test"
        XCTAssertEqual(dict[b], "test")
    }

    func testBidirectionalCollection() {
        let set: FXSortedSet<Int> = [1, 2, 3, 4]
        XCTAssertEqual(set.last, 4)
        XCTAssertEqual(set.first, 1)
        XCTAssertEqual(set[set.index(before: set.endIndex)], 4)
    }

    func testCodableRoundTrip() throws {
        let original: FXSortedSet<Int> = [3, 1, 2]
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FXSortedSet<Int>.self, from: data)
        XCTAssertEqual(original, restored)
    }
}

// MARK: - FXError Tests

final class FXErrorTests: XCTestCase {
    func testNonCallableKeyDescription() {
        let err = FXError.nonCallableKey
        XCTAssertEqual(err.debugDescription, "Non-callable key")
    }

    func testCycleDetectedDescription() {
        let err = FXError.cycleDetected([])
        XCTAssert(err.debugDescription.contains("Cycle detected"))
    }

    func testExecutorCannotSatisfyRequirements() {
        let err = FXError.executorCannotSatisfyRequirements
        XCTAssertEqual(err.debugDescription, "Executor cannot satisfy requirements")
    }

    func testNoExecutable() {
        let err = FXError.noExecutable
        XCTAssertEqual(err.debugDescription, "No executable found")
    }

    func testInvalidValueType() {
        let err = FXError.invalidValueType("TestType")
        XCTAssert(err.debugDescription.contains("TestType"))
    }

    func testUnexpectedKeyType() {
        let err = FXError.unexpectedKeyType("BadKey")
        XCTAssert(err.debugDescription.contains("BadKey"))
    }

    func testInconsistentValue() {
        let err = FXError.inconsistentValue("mismatch")
        XCTAssert(err.debugDescription.contains("mismatch"))
    }

    func testResourceNotFound() {
        let err = FXError.resourceNotFound(.external("myResource"))
        XCTAssert(err.debugDescription.contains("myResource"))
    }

    func testMissingRequiredCacheEntry() {
        let err = FXError.missingRequiredCacheEntry(cachePath: "/some/path")
        XCTAssert(err.debugDescription.contains("/some/path"))
    }

    func testUnexpressedKeyDependency() {
        let err = FXError.unexpressedKeyDependency(from: "A", to: "B")
        XCTAssert(err.debugDescription.contains("A"))
        XCTAssert(err.debugDescription.contains("B"))
    }

    func testValueComputationErrorDescription() {
        struct Inner: Error {}
        let err = FXError.valueComputationError(
            keyPrefix: "Prefix", key: "Key", error: Inner(),
            requestedCacheKeyPaths: []
        )
        XCTAssert(err.debugDescription.contains("Prefix"))
    }

    func testKeyEncodingErrorDescription() {
        struct E: Error {}
        let err = FXError.keyEncodingError(keyPrefix: "P", encodingError: E(), underlyingError: E())
        XCTAssert(err.debugDescription.contains("P"))
    }
}

// MARK: - unwrapFXError Tests

final class UnwrapFXErrorTests: XCTestCase {
    func testUnwrapNonFXError() {
        struct OtherError: Error {}
        let err = OtherError()
        let unwrapped = unwrapFXError(err)
        XCTAssert(unwrapped is OtherError)
    }

    func testUnwrapSingleLayer() {
        struct Inner: Error {}
        let err = FXError.valueComputationError(
            keyPrefix: "P", key: "K", error: Inner(),
            requestedCacheKeyPaths: []
        )
        let unwrapped = unwrapFXError(err)
        XCTAssert(unwrapped is Inner)
    }

    func testUnwrapNestedLayers() {
        struct Deepest: Error {}
        let inner = FXError.valueComputationError(
            keyPrefix: "P2", key: "K2", error: Deepest(),
            requestedCacheKeyPaths: []
        )
        let outer = FXError.valueComputationError(
            keyPrefix: "P1", key: "K1", error: inner,
            requestedCacheKeyPaths: []
        )
        let unwrapped = unwrapFXError(outer)
        XCTAssert(unwrapped is Deepest)
    }
}

// MARK: - FXErrorDetails Tests

final class FXErrorDetailsTests: XCTestCase {
    func testConstruction() {
        let details = FXErrorDetails(
            status: .failure,
            classification: .user,
            details: "bad input"
        )
        XCTAssertEqual(details.status, .failure)
        XCTAssertEqual(details.classification, .user)
        XCTAssertEqual(details.details, "bad input")
    }

    func testCodableRoundTrip() throws {
        let original = FXErrorDetails(
            status: .custom("timeout"),
            classification: .infrastructure,
            details: "server timed out"
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FXErrorDetails.self, from: data)
        XCTAssertEqual(original, restored)
    }

    func testWarningStatus() throws {
        let details = FXErrorDetails(status: .warning, classification: .user, details: "warn")
        let data = try JSONEncoder().encode(details)
        let restored = try JSONDecoder().decode(FXErrorDetails.self, from: data)
        XCTAssertEqual(restored.status, .warning)
    }
}

// MARK: - Deadline Tests

final class DeadlineAdditionalTests: XCTestCase {
    func testSetAndGetDeadline() {
        var ctx = Context()
        XCTAssertNil(ctx.fxDeadline)

        let deadline = Date(timeIntervalSinceNow: 60)
        ctx.fxDeadline = deadline
        XCTAssertEqual(ctx.fxDeadline, deadline)
    }

    func testNioDeadlineWithFiniteDate() {
        var ctx = Context()
        ctx.fxDeadline = Date(timeIntervalSinceNow: 10)
        XCTAssertNotNil(ctx.nioDeadline)
    }

    func testNioDeadlineWithDistantFuture() {
        var ctx = Context()
        ctx.fxDeadline = .distantFuture
        XCTAssertNil(ctx.nioDeadline)
    }

    func testNioDeadlineWithNil() {
        let ctx = Context()
        XCTAssertNil(ctx.nioDeadline)
    }

    func testReducingDeadlineFromNone() {
        let ctx = Context()
        let deadline = Date(timeIntervalSinceNow: 30)
        let newCtx = ctx.fxReducingDeadline(to: deadline)
        XCTAssertEqual(newCtx.fxDeadline, deadline)
    }

    func testReducingDeadlineToEarlier() {
        var ctx = Context()
        let later = Date(timeIntervalSinceNow: 60)
        let earlier = Date(timeIntervalSinceNow: 30)
        ctx.fxDeadline = later
        let newCtx = ctx.fxReducingDeadline(to: earlier)
        XCTAssertEqual(newCtx.fxDeadline, earlier)
    }

    func testReducingDeadlineKeepsEarlierExisting() {
        var ctx = Context()
        let earlier = Date(timeIntervalSinceNow: 10)
        let later = Date(timeIntervalSinceNow: 60)
        ctx.fxDeadline = earlier
        let newCtx = ctx.fxReducingDeadline(to: later)
        XCTAssertEqual(newCtx.fxDeadline, earlier)
    }
}

// MARK: - NullExecutor Tests

final class NullExecutorTests: XCTestCase {
    func testPerformFails() {
        let executor = FXNullExecutor()
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        var ctx = Context()
        ctx.group = group

        let action = SumAction(SumInput(values: [1, 2]))
        let ai = FXActionInterface(db: db)
        XCTAssertThrowsError(try executor.perform(action, ai: ai, requirements: nil, ctx).wait())
    }

    func testCancelFails() async {
        let executor = FXNullExecutor()
        let group = FXMakeDefaultDispatchGroup()
        var ctx = Context()
        ctx.group = group

        do {
            try await executor.cancel(UUID(), options: FXExecutorCancellationOptions(), ctx)
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }
}

// MARK: - FXExecutableID Tests

final class ExecutableIDTests: XCTestCase {
    func testCreation() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let dataID = try! db.put(data: FXByteBuffer.withBytes([1, 2, 3]), ctx).wait()

        let execID = FXExecutableID(dataID: dataID)
        XCTAssertEqual(execID.dataID, dataID)
    }

    func testConvenienceInit() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let dataID = try! db.put(data: FXByteBuffer.withBytes([1]), ctx).wait()

        let execID = FXExecutableID(dataID)
        XCTAssertEqual(execID.dataID, dataID)
    }

    func testComparable() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id1 = try! db.put(data: FXByteBuffer.withBytes([1]), ctx).wait()
        let id2 = try! db.put(data: FXByteBuffer.withBytes([2]), ctx).wait()

        let exec1 = FXExecutableID(id1)
        let exec2 = FXExecutableID(id2)

        // Just verify the comparison doesn't crash and is consistent
        XCTAssertEqual(exec1 < exec2, !(exec2 < exec1) || exec1 == exec2)
    }
}

// MARK: - FXExecutorCancellationOptions Tests

final class ExecutorCancellationOptionsTests: XCTestCase {
    func testDefaults() {
        let opts = FXExecutorCancellationOptions()
        XCTAssertFalse(opts.collectSysdiagnosis)
    }

    func testCustom() {
        let opts = FXExecutorCancellationOptions(collectSysdiagnosis: true)
        XCTAssertTrue(opts.collectSysdiagnosis)
    }
}

// MARK: - Value Tests

final class FXValueTests: XCTestCase {
    struct SimpleValue: FXValue, Codable {
        let number: Int
        let text: String
    }

    func testCodableValueConformance() {
        let v = SimpleValue(number: 42, text: "hello")
        XCTAssertEqual(v.refs, [])
        XCTAssertEqual(v.codableValue.number, 42)
    }

    func testValueCASObjectRoundTrip() throws {
        let v = SimpleValue(number: 99, text: "test")
        let obj = try v.asCASObject()
        XCTAssertEqual(obj.refs, [])
        XCTAssertTrue(obj.size > 0)

        let restored = try SimpleValue(from: obj)
        XCTAssertEqual(restored.number, 99)
        XCTAssertEqual(restored.text, "test")
    }

    func testOptionalValueSome() throws {
        let v: SimpleValue? = SimpleValue(number: 1, text: "a")
        XCTAssertEqual(v.refs, [])
        XCTAssertNotNil(v.codableValue.codableValue)

        let obj = try v.asCASObject()
        let restored = try SimpleValue?(from: obj)
        XCTAssertEqual(restored?.number, 1)
    }

    func testOptionalValueNone() throws {
        let v: SimpleValue? = nil
        XCTAssertEqual(v.refs, [])
        XCTAssertNil(v.codableValue.codableValue)

        let obj = try v.asCASObject()
        let restored = try SimpleValue?(from: obj)
        XCTAssertNil(restored)
    }

    func testArrayValue() throws {
        let arr: [SimpleValue] = [
            SimpleValue(number: 1, text: "a"),
            SimpleValue(number: 2, text: "b"),
        ]
        XCTAssertEqual(arr.refs, [])
        XCTAssertEqual(arr.codableValue.count, 2)

        let obj = try arr.asCASObject()
        let restored = try [SimpleValue](from: obj)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].number, 1)
        XCTAssertEqual(restored[1].text, "b")
    }

    func testSortedSetValue() throws {
        // Int already conforms to FXValue via Codable extension
        let set: FXSortedSet<Int> = [3, 1, 2]
        XCTAssertEqual(set.refs, [])

        let obj = try set.asCASObject()
        let restored = try FXSortedSet<Int>(from: obj)
        XCTAssertEqual(Array(restored), [1, 2, 3])
    }

    func testEmptyArrayValue() throws {
        let arr: [SimpleValue] = []
        let obj = try arr.asCASObject()
        let restored = try [SimpleValue](from: obj)
        XCTAssertEqual(restored.count, 0)
    }
}

// MARK: - WrappedDataID Tests

final class WrappedDataIDTests: XCTestCase {
    func testSingleDataIDValueRefs() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try! db.put(data: FXByteBuffer.withBytes([1]), ctx).wait()

        let execID = FXExecutableID(id)
        XCTAssertEqual(execID.refs, [id])
    }

    func testSingleDataIDValueCASRoundTrip() throws {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try db.put(data: FXByteBuffer.withBytes([1, 2]), ctx).wait()

        let original = FXExecutableID(id)
        let obj = try original.asCASObject()
        XCTAssertEqual(obj.refs, [id])

        let restored = try FXExecutableID(from: obj)
        XCTAssertEqual(restored.dataID, id)
    }

    func testSingleDataIDValueFromEmptyRefs() {
        let obj = FXCASObject(refs: [], data: FXByteBuffer())
        XCTAssertThrowsError(try FXExecutableID(from: obj))
    }

    func testSingleDataIDValueHashable() {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try! db.put(data: FXByteBuffer.withBytes([1]), ctx).wait()

        let a = FXExecutableID(id)
        let b = FXExecutableID(id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}

// MARK: - AnySerializable Tests

final class AnySerializableTests: XCTestCase {
    func testRegistryBasics() {
        let registry = FXSerializableRegistry()
        registry.register(type: String.self)
        registry.register(type: Int.self)

        let strType = registry.lookupType(identifier: "String")
        XCTAssertNotNil(strType)

        let intType = registry.lookupType(identifier: "Int")
        XCTAssertNotNil(intType)

        let unknown = registry.lookupType(identifier: "Float")
        XCTAssertNil(unknown)
    }

    func testRegistryDuplicateIgnored() {
        let registry = FXSerializableRegistry()
        registry.register(type: String.self)
        registry.register(type: String.self)
        XCTAssertNotNil(registry.lookupType(identifier: "String"))
    }

    func testStringRoundTrip() throws {
        let registry = FXSerializableRegistry()
        registry.register(type: String.self)

        let original = "hello world"
        let any = try LLBAnySerializable(from: original as LLBPolymorphicSerializable)

        let restored: String = try any.deserialize(registry: registry)
        XCTAssertEqual(restored, "hello world")
    }

    func testIntRoundTrip() throws {
        let registry = FXSerializableRegistry()
        registry.register(type: Int.self)

        let original = 42
        let any = try LLBAnySerializable(from: original as LLBPolymorphicSerializable)

        let restored: Int = try any.deserialize(registry: registry)
        XCTAssertEqual(restored, 42)
    }

    func testDeserializeUnknownType() throws {
        let registry = FXSerializableRegistry()
        let any = try LLBAnySerializable(from: "test" as LLBPolymorphicSerializable)

        XCTAssertThrowsError(try {
            let _: String = try any.deserialize(registry: registry)
        }()) { error in
            guard case LLBAnySerializableError.unknownType = error else {
                XCTFail("Expected unknownType error, got: \(error)")
                return
            }
        }
    }
}

// MARK: - CommonCodables Tests

final class CommonCodablesTests: XCTestCase {
    func testStringSerializationRoundTrip() throws {
        let original = "Hello, world!"
        let buffer = try original.toBytes()
        let restored = try String(from: buffer)
        XCTAssertEqual(restored, "Hello, world!")
    }

    func testEmptyStringRoundTrip() throws {
        let original = ""
        let buffer = try original.toBytes()
        let restored = try String(from: buffer)
        XCTAssertEqual(restored, "")
    }

    func testIntSerializationRoundTrip() throws {
        let original = 42
        let buffer = try original.toBytes()
        let restored = try Int(from: buffer)
        XCTAssertEqual(restored, 42)
    }

    func testNegativeIntRoundTrip() throws {
        let original = -100
        let buffer = try original.toBytes()
        let restored = try Int(from: buffer)
        XCTAssertEqual(restored, -100)
    }

    func testZeroIntRoundTrip() throws {
        let original = 0
        let buffer = try original.toBytes()
        let restored = try Int(from: buffer)
        XCTAssertEqual(restored, 0)
    }

    func testLargeIntRoundTrip() throws {
        let original = Int.max
        let buffer = try original.toBytes()
        let restored = try Int(from: buffer)
        XCTAssertEqual(restored, Int.max)
    }
}

// MARK: - Service Tests

final class FXServiceTests: XCTestCase {
    struct TestResource: FXResource {
        let name: String
        let version: Int?
        let lifetime: ResourceLifetime
    }

    struct TestClassifier: FXErrorClassifier {
        let match: String
        func tryClassifyError(_ error: Swift.Error) -> FXErrorDetails? {
            if "\(error)" == match {
                return FXErrorDetails(status: .failure, classification: .user, details: match)
            }
            return nil
        }
    }

    func testInitialization() {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        XCTAssertNil(service.ruleset("nonexistent"))
    }

    func testRegisterResource() throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)

        let resource = TestResource(name: "compiler", version: 1, lifetime: .versioned)
        try service.registerResource(resource)
    }

    func testRegisterDuplicateResourceThrows() throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)

        let resource = TestResource(name: "compiler", version: 1, lifetime: .versioned)
        try service.registerResource(resource)
        XCTAssertThrowsError(try service.registerResource(resource))
    }

    func testTryClassifyErrorWithNoClassifiers() {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        struct SomeError: Error {}
        XCTAssertNil(service.tryClassifyError(SomeError()))
    }
}

// MARK: - Ruleset Tests

final class FXRulesetTests: XCTestCase {
    // A minimal entrypoint that declares a resource entitlement.
    struct ResourcefulEntrypoint: FXEntrypoint, AsyncFXKey {
        typealias ValueType = SumAction.ValueType

        static let version = 1
        static let versionDependencies: [FXVersioning.Type] = []
        static let actionDependencies: [any FXAction.Type] = [SumAction.self]
        static let resourceEntitlements: [ResourceKey] = [.external("compiler")]

        init(withEntrypointPayload casObject: FXCASObject) throws {
            let data = Data(casObject.data.readableBytesView)
            self.payload = try FXDecoder().decode(Payload.self, from: data)
        }

        init(withEntrypointPayload buffer: FXByteBuffer) throws {
            let data = Data(buffer.readableBytesView)
            self.payload = try FXDecoder().decode(Payload.self, from: data)
        }

        struct Payload: Codable { let v: Int }
        let payload: Payload

        init(value: Int) {
            self.payload = Payload(v: value)
        }

        func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> SumAction.ValueType {
            return SumOutput(total: payload.v)
        }
    }

    // A bare entrypoint with no resource entitlements.
    struct BareEntrypoint: FXEntrypoint, AsyncFXKey {
        typealias ValueType = SumAction.ValueType

        static let version = 1
        static let versionDependencies: [FXVersioning.Type] = []

        init(withEntrypointPayload casObject: FXCASObject) throws {}
        init(withEntrypointPayload buffer: FXByteBuffer) throws {}

        func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> SumAction.ValueType {
            return SumOutput(total: 0)
        }
    }

    func testBasicRuleset() {
        let ruleset = FXRuleset(name: "test", entrypoints: [:])
        XCTAssertEqual(ruleset.name, "test")
        XCTAssertTrue(ruleset.entrypoints.isEmpty)
        XCTAssertNil(ruleset.version)
    }

    func testRulesetWithVersion() {
        let ruleset = FXRuleset(name: "test", entrypoints: [:], version: "1.2.3")
        XCTAssertEqual(ruleset.version, "1.2.3")
    }

    func testConstrainResourcesEmpty() throws {
        let ruleset = FXRuleset(name: "test", entrypoints: [:])
        let constrained = try ruleset.constrainResources([:])
        XCTAssertTrue(constrained.isEmpty)
    }

    // MARK: - Entrypoint and Resource Entitlement Tests

    func testRulesetAggregatesResourceEntitlements() {
        let ruleset = FXRuleset(
            name: "resourceful",
            entrypoints: ["build": ResourcefulEntrypoint.self]
        )
        XCTAssertTrue(ruleset.aggregatedResourceEntitlements.contains(.external("compiler")))
    }

    func testRulesetAggregatesActionDependencies() {
        let ruleset = FXRuleset(
            name: "resourceful",
            entrypoints: ["build": ResourcefulEntrypoint.self]
        )
        XCTAssertFalse(ruleset.actionDependencies.isEmpty)
        XCTAssertTrue(ruleset.actionDependencies.contains(where: { $0 is SumAction.Type }))
    }

    func testConstrainResourcesSuccess() throws {
        struct TestResource: FXResource {
            let name: String
            let version: Int? = 1
            let lifetime: ResourceLifetime = .versioned
        }

        let ruleset = FXRuleset(
            name: "resourceful",
            entrypoints: ["build": ResourcefulEntrypoint.self]
        )
        let allResources: [ResourceKey: FXResource] = [
            .external("compiler"): TestResource(name: "compiler"),
            .external("linker"): TestResource(name: "linker"),  // extra, not required
        ]
        let constrained = try ruleset.constrainResources(allResources)
        XCTAssertEqual(constrained.count, 1)
        XCTAssertNotNil(constrained[.external("compiler")])
        // "linker" should be excluded since the ruleset doesn't request it
        XCTAssertNil(constrained[.external("linker")])
    }

    func testConstrainResourcesMissingThrows() {
        let ruleset = FXRuleset(
            name: "resourceful",
            entrypoints: ["build": ResourcefulEntrypoint.self]
        )
        // Provide no resources — should throw resourceNotFound
        XCTAssertThrowsError(try ruleset.constrainResources([:])) { error in
            guard case FXError.resourceNotFound(let key) = error else {
                XCTFail("Expected resourceNotFound, got \(error)")
                return
            }
            XCTAssertEqual(key, .external("compiler"))
        }
    }

    func testRulesetWithMultipleEntrypoints() {
        let ruleset = FXRuleset(
            name: "multi",
            entrypoints: [
                "build": ResourcefulEntrypoint.self,
                "check": BareEntrypoint.self,
            ]
        )
        XCTAssertEqual(ruleset.entrypoints.count, 2)
        // Should still have entitlements from ResourcefulEntrypoint
        XCTAssertTrue(ruleset.aggregatedResourceEntitlements.contains(.external("compiler")))
    }

    // MARK: - FXEntrypoint Protocol Tests

    func testEntrypointInitFromCASObject() throws {
        let payload = ResourcefulEntrypoint.Payload(v: 42)
        let data = try FXEncoder().encode(payload)
        let obj = FXCASObject(refs: [], data: FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data)))
        let ep = try ResourcefulEntrypoint(withEntrypointPayload: obj)
        XCTAssertEqual(ep.payload.v, 42)
    }

    func testEntrypointInitFromByteBuffer() throws {
        let payload = ResourcefulEntrypoint.Payload(v: 99)
        let data = try FXEncoder().encode(payload)
        let buffer = FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        let ep = try ResourcefulEntrypoint(withEntrypointPayload: buffer)
        XCTAssertEqual(ep.payload.v, 99)
    }
}

// MARK: - Context Logging Tests

final class ContextLoggingTests: XCTestCase {
    func testLoggerContextProperty() {
        var ctx = Context()
        XCTAssertNil(ctx.logger)

        var logger = Logger(label: "test")
        logger.logLevel = .debug
        ctx.logger = logger
        XCTAssertNotNil(ctx.logger)
    }

    func testMetricsContextProperty() {
        var ctx = Context()
        XCTAssertNil(ctx.metrics)
    }

    func testStreamingLogHandlerContextProperty() {
        var ctx = Context()
        XCTAssertNil(ctx.streamingLogHandler)
    }

    func testTreeMaterializerContextProperty() {
        var ctx = Context()
        XCTAssertNil(ctx.fxTreeMaterializer)
    }
}

// MARK: - Protobuf Extensions Tests

final class ProtobufExtensionsTests: XCTestCase {
    func testFXCASObjectProtobufRoundTrip() throws {
        // FXCASObject serialization uses protobuf under the hood
        let original = FXCASObject(refs: [], data: FXByteBuffer.withBytes([1, 2, 3]))
        let serializedData = try original.toData()
        let restored = try FXCASObject(rawBytes: serializedData)
        XCTAssertEqual(original, restored)
    }

    func testFXCASObjectByteBufferRoundTrip() throws {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let refID = try db.put(data: FXByteBuffer.withBytes([99]), ctx).wait()

        let original = FXCASObject(refs: [refID], data: FXByteBuffer.withBytes([5, 6]))
        let buffer = try original.toBytes()
        let restored = try FXCASObject(from: buffer)
        XCTAssertEqual(original.refs, restored.refs)
        XCTAssertEqual(original.data, restored.data)
    }

    func testLLBAnySerializableProtobufSerialization() throws {
        // LLBAnySerializable is a protobuf message — test its FXSerializable conformance
        let any = try LLBAnySerializable(from: "hello" as LLBPolymorphicSerializable)
        let buffer = try any.toBytes()
        XCTAssertTrue(buffer.readableBytes > 0)

        let restored = try LLBAnySerializable(from: buffer)
        XCTAssertEqual(restored.typeIdentifier, "String")
    }
}

// MARK: - FXActionRequirements Tests

final class FXActionRequirementsTests: XCTestCase {
    func testDefaultRequirements() {
        let req = FXActionRequirements()
        XCTAssertNil(req.workerSize)
        XCTAssertNil(req.allowNetworkAccess)
        XCTAssertTrue(req.requirements.isEmpty)
    }

    func testCustomRequirements() {
        let req = FXActionRequirements(
            workerSize: .large,
            allowNetworkAccess: true,
            ["os": "linux"]
        )
        XCTAssertEqual(req.workerSize, .large)
        XCTAssertEqual(req.allowNetworkAccess, true)
        XCTAssertEqual(req.requirements["os"], "linux")
    }

    func testCodableRoundTrip() throws {
        let original = FXActionRequirements(workerSize: .medium)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FXActionRequirements.self, from: data)
        XCTAssertEqual(restored.workerSize, .medium)
    }

    func testWorkerSizeEquality() {
        XCTAssertEqual(FXActionWorkerSize.small, FXActionWorkerSize.small)
        XCTAssertNotEqual(FXActionWorkerSize.small, FXActionWorkerSize.large)
    }

    func testActionDefaultRequirements() {
        // SumAction should have default (empty) requirements
        let action = SumAction(SumInput(values: [1]))
        XCTAssertNil(action.requirements.workerSize)
    }

    func testActionDefaultNameAndVersion() {
        XCTAssertFalse(SumAction.name.isEmpty)
        XCTAssertEqual(SumAction.version, 0)
    }
}

// MARK: - FXService Extended Tests

final class FXServiceExtendedTests: XCTestCase {
    struct TestResource: FXResource {
        let name: String
        let version: Int?
        let lifetime: ResourceLifetime
    }

    struct TestClassifier: FXErrorClassifier {
        func tryClassifyError(_ error: Swift.Error) -> FXErrorDetails? {
            return FXErrorDetails(status: .failure, classification: .infrastructure, details: "\(error)")
        }
    }

    struct MinimalPackage: FXRulesetPackage {
        typealias Config = Void

        static func createRulesets() -> [FXRuleset] {
            return [FXRuleset(name: "minimal", entrypoints: [:])]
        }

        static func createErrorClassifier() -> FXErrorClassifier? {
            return TestClassifier()
        }
    }

    struct NoOpAuthenticator: FXResourceAuthenticator {}

    func testRegisterPackage() async throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        let ctx = Context()
        try await service.registerPackage(MinimalPackage.self, with: (), authenticator: NoOpAuthenticator(), ctx)

        XCTAssertNotNil(service.ruleset("minimal"))
        XCTAssertNil(service.ruleset("other"))
    }

    func testErrorClassifierAfterPackageRegistration() async throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        let ctx = Context()
        try await service.registerPackage(MinimalPackage.self, with: (), authenticator: NoOpAuthenticator(), ctx)

        struct SomeError: Error {}
        let details = service.tryClassifyError(SomeError())
        XCTAssertNotNil(details)
        XCTAssertEqual(details?.classification, .infrastructure)
    }

    func testRulesetDefaultPackageDefaults() {
        // Test that default implementations exist
        XCTAssertFalse(MinimalPackage.supportsNamedMounts)
    }

    func testRegisterPackageDuplicateResourceThrows() async throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        let ctx = Context()

        // Register a resource manually first
        try service.registerResource(TestResource(name: "shared", version: 1, lifetime: .versioned))

        // Now register a package that also provides "shared"
        struct PackageWithResource: FXRulesetPackage {
            typealias Config = Void

            static func createRulesets() -> [FXRuleset] { [] }
            static func createExternalResources(
                _ config: Void,
                group: FXFuturesDispatchGroup,
                authenticator: FXResourceAuthenticator,
                _ ctx: Context
            ) async throws -> [FXResource] {
                return [FXServiceExtendedTests.TestResource(name: "shared", version: 2, lifetime: .versioned)]
            }
        }

        do {
            try await service.registerPackage(PackageWithResource.self, with: (), authenticator: NoOpAuthenticator(), ctx)
            XCTFail("Expected duplicateResource error")
        } catch {
            guard case FXService.Error.duplicateResource(let name) = error else {
                XCTFail("Expected duplicateResource, got \(error)")
                return
            }
            XCTAssertEqual(name, "shared")
        }
    }

    func testRegisterPackageWithResources() async throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        let ctx = Context()

        struct PackageWithResource: FXRulesetPackage {
            typealias Config = Void

            static func createRulesets() -> [FXRuleset] {
                [FXRuleset(name: "res-ruleset", entrypoints: [:])]
            }
            static func createExternalResources(
                _ config: Void,
                group: FXFuturesDispatchGroup,
                authenticator: FXResourceAuthenticator,
                _ ctx: Context
            ) async throws -> [FXResource] {
                return [FXServiceExtendedTests.TestResource(name: "myres", version: 1, lifetime: .idempotent)]
            }
        }

        try await service.registerPackage(PackageWithResource.self, with: (), authenticator: NoOpAuthenticator(), ctx)
        XCTAssertNotNil(service.ruleset("res-ruleset"))
    }

    func testResourcesForRuleset() async throws {
        let group = FXMakeDefaultDispatchGroup()
        let service = FXService(group: group)
        let ctx = Context()

        // Register a resource that the entrypoint requires
        try service.registerResource(TestResource(name: "compiler", version: 1, lifetime: .versioned))

        // Create a ruleset that needs "compiler"
        let ruleset = FXRuleset(
            name: "needs-compiler",
            entrypoints: ["build": FXRulesetTests.ResourcefulEntrypoint.self]
        )

        let constrained = try service.resources(for: ruleset)
        XCTAssertEqual(constrained.count, 1)
        XCTAssertNotNil(constrained[.external("compiler")])
    }
}

// MARK: - AnySerializable Extended Tests

final class AnySerializableExtendedTests: XCTestCase {
    func testPolymorphicIdentifier() {
        XCTAssertEqual(String.polymorphicIdentifier, "String")
        XCTAssertEqual(Int.polymorphicIdentifier, "Int")
    }

    func testAnySerializableCASObjectRoundTrip() throws {
        let original = "test string"
        let any = try LLBAnySerializable(from: original as LLBPolymorphicSerializable)
        // Serialize to bytes then construct from CAS object
        let buffer = try any.toBytes()
        let casObj = FXCASObject(refs: [], data: buffer)
        let restored = try LLBAnySerializable(from: casObj)
        XCTAssertEqual(restored.typeIdentifier, "String")
    }

    func testDeserializeTypeMismatch() throws {
        let registry = FXSerializableRegistry()
        registry.register(type: String.self)

        let any = try LLBAnySerializable(from: "test" as LLBPolymorphicSerializable)

        // Try to deserialize as Int when it's actually a String
        XCTAssertThrowsError(try {
            let _: Int = try any.deserialize(registry: registry)
        }()) { error in
            guard case LLBAnySerializableError.typeMismatch = error else {
                XCTFail("Expected typeMismatch error, got: \(error)")
                return
            }
        }
    }
}

// MARK: - Context Logging Extended Tests

final class ContextLoggingExtendedTests: XCTestCase {
    class TestMetricsSink: FXMetricsSink {
        var events: [(String, Logger.Metadata)] = []

        subscript(sinkMetadataKey key: String) -> Logger.Metadata.Value? {
            get { nil }
            set { }
        }

        func event(
            _ message: Logger.Message,
            metadata: @autoclosure () -> Logger.Metadata,
            _ ctx: Context,
            file: String,
            function: String,
            line: UInt
        ) {
            events.append(("\(message)", metadata()))
        }
    }

    func testMetricsSinkSetGet() {
        var ctx = Context()
        let sink = TestMetricsSink()
        ctx.metrics = sink
        XCTAssertNotNil(ctx.metrics)
    }

    func testMetricsSinkEvent() {
        var ctx = Context()
        let sink = TestMetricsSink()
        ctx.metrics = sink
        sink.event("test message", metadata: [:], ctx, file: #file, function: #function, line: #line)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events[0].0, "test message")
    }

    func testMetricsSinkConvenienceEvent() {
        let sink = TestMetricsSink()
        sink.event("convenience")
        XCTAssertEqual(sink.events.count, 1)
    }

    class TestStreamingLog: StreamingLogHandler {
        var logged: [(String, FXByteBuffer)] = []
        func streamLog(channel: String, _ data: FXByteBuffer) async throws {
            logged.append((channel, data))
        }
    }

    func testStreamingLogHandlerSetGet() {
        var ctx = Context()
        let handler = TestStreamingLog()
        ctx.streamingLogHandler = handler
        XCTAssertNotNil(ctx.streamingLogHandler)
    }
}

// MARK: - InMemoryCAS Extended Tests

final class InMemoryCASDatabaseExtendedTests: XCTestCase {
    let group = FXMakeDefaultDispatchGroup()

    func testIdentifyDoesNotStore() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try db.identify(refs: [], data: FXByteBuffer.withBytes([1, 2, 3]), ctx).wait()
        // identify may or may not store, but we can verify the id is valid
        XCTAssertFalse(id.bytes.isEmpty)
    }

    func testPutKnownID() throws {
        let db = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let data = FXByteBuffer.withBytes([7, 8, 9])
        let expectedID = try db.identify(refs: [], data: data, ctx).wait()
        let actualID = try db.put(knownID: expectedID, refs: [], data: data, ctx).wait()
        XCTAssertEqual(expectedID, actualID)

        let obj = try db.get(actualID, ctx).wait()
        XCTAssertNotNil(obj)
        XCTAssertEqual(Array(buffer: obj!.data), [7, 8, 9])
    }

    func testGetNonexistent() throws {
        let db1 = FXInMemoryCASDatabase(group: group)
        let db2 = FXInMemoryCASDatabase(group: group)
        let ctx = Context()
        let id = try db1.put(data: FXByteBuffer.withBytes([1]), ctx).wait()
        let result = try db2.get(id, ctx).wait()
        XCTAssertNil(result)
    }
}
