// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

public protocol FXValue: Sendable {
    associatedtype DataID: FXDataIDProtocol = FXDataID
    associatedtype CodableValueType: Codable

    var refs: [DataID] { get }
    var codableValue: CodableValueType { get }

    init(refs: [DataID], codableValue: CodableValueType) throws
}

extension FXValue where Self: Codable, DataID == FXDataID {
    public var refs: [FXDataID] { [] }
    public var codableValue: Self { self }
    public init(refs: [FXDataID], codableValue: Self) {
        self = codableValue
    }
}

public final class CASCodableOptional<T: Codable>: Codable {
    let codableValue: T?
    init(codableValue: T?) {
        self.codableValue = codableValue
    }
}

extension Optional: FXValue where Wrapped: FXValue {
    public var refs: [Wrapped.DataID] {
        switch self {
        case .none:
            return []
        case .some(let value):
            return value.refs
        }
    }

    public var codableValue: CASCodableOptional<Wrapped.CodableValueType> {
        switch self {
        case .none:
            return CASCodableOptional(codableValue: nil)
        case .some(let value):
            return CASCodableOptional(codableValue: value.codableValue)
        }
    }

    public init(refs: [Wrapped.DataID], codableValue: CASCodableOptional<Wrapped.CodableValueType>) throws {
        guard let value: Wrapped.CodableValueType = codableValue.codableValue else {
            self = .none
            return
        }

        self = .some(try Wrapped(refs: refs, codableValue: value))
    }
}

public class CASCodableElement<T: Codable>: Codable {
    let refsCount: Int
    let codable: T

    init(refsCount: Int, codable: T) {
        self.refsCount = refsCount
        self.codable = codable
    }
}

extension FXSortedSet: FXValue where Element: FXValue {
    public var refs: [Element.DataID] {
        map { $0.refs }.flatMap { $0 }
    }

    public var codableValue: [CASCodableElement<Element.CodableValueType>] {
        map { CASCodableElement(refsCount: $0.refs.count, codable: $0.codableValue) }
    }

    public init(refs: [Element.DataID], codableValue: [CASCodableElement<Element.CodableValueType>]) throws {
        let refsCountSum = codableValue.map { $0.refsCount }.reduce(0, +)
        assert(refs.count == refsCountSum)

        var refRanges = [Range<Int>]()
        for element in codableValue {
            let base = refRanges.last?.endIndex ?? 0
            let range = base..<(base + element.refsCount)
            refRanges.append(range)
        }

        let elements: [Element] = try codableValue.enumerated().map { (idx, element) in
            let range: Range<Int> = refRanges[idx]
            let slice: ArraySlice<Element.DataID> = refs[range]
            let objRefs: [Element.DataID] = [Element.DataID](slice)
            return try Element(refs: objRefs, codableValue: element.codable)
        }

        self = Self(elements)
    }
}

extension Array: FXValue where Element: FXValue {
    public var refs: [Element.DataID] {
        self.map { $0.refs }.flatMap { $0 }
    }

    public var codableValue: [CASCodableElement<Element.CodableValueType>] {
        self.map { CASCodableElement(refsCount: $0.refs.count, codable: $0.codableValue) }
    }

    public init(refs: [Element.DataID], codableValue: [CASCodableElement<Element.CodableValueType>]) throws {
        let refsCountSum = codableValue.map { $0.refsCount }.reduce(0, +)
        assert(refs.count == refsCountSum)

        var refRanges = [Range<Int>]()
        for element in codableValue {
            let base = refRanges.last?.endIndex ?? 0
            let range = base..<(base + element.refsCount)
            refRanges.append(range)
        }

        self = try codableValue.enumerated().map { (idx, element) in
            let range: Range<Int> = refRanges[idx]
            let slice: ArraySlice<Element.DataID> = refs[range]
            let objRefs: [Element.DataID] = [Element.DataID](slice)
            return try Element(refs: objRefs, codableValue: element.codable)
        }
    }
}

extension FXValue where DataID == FXDataID /* FXCASObjectRepresentable */ {
    public func asCASObject() throws -> FXCASObject {
        let data = try FXEncoder().encode(codableValue)
        let buffer = FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return FXCASObject(refs: refs, data: buffer)
    }
}

extension FXValue /* Generic CASObject conversion */ {
    public func asCASObject<O: FXCASObjectProtocol>() throws -> O where O.DataID == DataID {
        let data = try FXEncoder().encode(codableValue)
        let buffer = FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return O(refs: refs, data: buffer)
    }
}

extension FXValue where DataID == FXDataID /* FXCASObjectConstructable */ {
    public init(from casObject: FXCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableValueType.self, from: data)

        self = try Self(refs: casObject.refs, codableValue: codable)
    }
}

extension FXValue /* Generic CASObject construction */ {
    public init<O: FXCASObjectProtocol>(from casObject: O) throws where O.DataID == DataID {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableValueType.self, from: data)

        self = try Self(refs: casObject.refs, codableValue: codable)
    }
}

private struct IgnoredCodable: Codable {}

private struct IgnoredValue<DataID: FXDataIDProtocol>: FXValue {
    let refs: [DataID]
    let codableValue: IgnoredCodable

    init(refs: [DataID], codableValue: CodableValueType) {
        self.refs = refs
        self.codableValue = codableValue
    }
}

public func FXRequestedCacheKeyPaths<O: FXCASObjectProtocol>(for cachedValue: O) throws -> FXSortedSet<String> {
    let internalValue = try InternalValue<IgnoredValue<O.DataID>>(from: cachedValue)
    guard let keyPaths = internalValue.metadata.requestedCacheKeyPaths else {
        return []
    }

    return keyPaths
}


struct FXValueMetadata: Codable {
    let requestedCacheKeyPaths: FXSortedSet<String>?

    var creationDate: String? = ISO8601DateFormatter().string(from: Date())

    init(requestedCacheKeyPaths: FXSortedSet<String>) {
        self.requestedCacheKeyPaths = requestedCacheKeyPaths
    }
}

internal protocol InternalResult: AnyObject, Sendable {}

final class InternalValue<V: FXValue>: InternalResult {
    let value: V
    let metadata: FXValueMetadata

    convenience init(_ value: V, requestedCacheKeyPaths: FXSortedSet<String>) {
        let m = FXValueMetadata(requestedCacheKeyPaths: requestedCacheKeyPaths)
        self.init(value, metadata: m)
    }

    private init(_ value: V, metadata: FXValueMetadata) {
        self.value = value
        self.metadata = metadata
    }
}

private final class CodableInternalValue<V: FXValue>: Codable {
    let value: V.CodableValueType
    let metadata: FXValueMetadata

    init(_ value: V, metadata: FXValueMetadata) {
        self.value = value.codableValue
        self.metadata = metadata
    }
}

extension InternalValue: FXCASObjectRepresentable where V.DataID == FXDataID {
    func asCASObject() throws -> FXCASObject {
        let codable = CodableInternalValue(value, metadata: metadata)
        let data = try FXEncoder().encode(codable)
        let buffer = FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return FXCASObject(refs: value.refs, data: buffer)
    }
}

extension InternalValue {
    func asCASObject<O: FXCASObjectProtocol>() throws -> O where O.DataID == V.DataID {
        let codable = CodableInternalValue(value, metadata: metadata)
        let data = try FXEncoder().encode(codable)
        let buffer = FXByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return O(refs: value.refs, data: buffer)
    }
}

extension InternalValue: FXCASObjectConstructable where V.DataID == FXDataID {
    convenience init(from casObject: FXCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableInternalValue<V>.self, from: data)
        let value = try V(refs: casObject.refs, codableValue: codable.value)
        self.init(value, metadata: codable.metadata)
    }
}

extension InternalValue {
    convenience init<O: FXCASObjectProtocol>(from casObject: O) throws where O.DataID == V.DataID {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableInternalValue<V>.self, from: data)
        let value = try V(refs: casObject.refs, codableValue: codable.value)
        self.init(value, metadata: codable.metadata)
    }
}

extension InternalValue: FXResult where V.DataID == FXDataID {}
