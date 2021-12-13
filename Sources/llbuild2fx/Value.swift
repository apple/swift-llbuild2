// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import llbuild2

public protocol FXValue {
    associatedtype CodableValueType: Codable

    var refs: [LLBDataID] { get }
    var codableValue: CodableValueType { get }

    init(refs: [LLBDataID], codableValue: CodableValueType) throws
}

extension FXValue where Self: Codable {
    public var refs: [LLBDataID] { [] }
    public var codableValue: Self { self }
    public init(refs: [LLBDataID], codableValue: Self) {
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
    public var refs: [LLBDataID] {
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

    public init(refs: [LLBDataID], codableValue: CASCodableOptional<Wrapped.CodableValueType>) throws {
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

extension Array: FXValue where Element: FXValue {
    public var refs: [LLBDataID] {
        self.map { $0.refs }.flatMap { $0 }
    }

    public var codableValue: [CASCodableElement<Element.CodableValueType>] {
        self.map { CASCodableElement(refsCount: $0.refs.count, codable: $0.codableValue) }
    }

    public init(refs: [LLBDataID], codableValue: [CASCodableElement<Element.CodableValueType>]) throws {
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
            let slice: ArraySlice<LLBDataID> = refs[range]
            let objRefs: [LLBDataID] = [LLBDataID](slice)
            return try Element(refs: objRefs, codableValue: element.codable)
        }
    }
}

extension FXValue /* LLBCASObjectRepresentable */ {
    public func asCASObject() throws -> LLBCASObject {
        let data = try FXEncoder().encode(codableValue)
        let buffer = LLBByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return LLBCASObject(refs: refs, data: buffer)
    }
}

extension FXValue /* LLBCASObjectConstructable */ {
    public init(from casObject: LLBCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableValueType.self, from: data)

        self = try Self(refs: casObject.refs, codableValue: codable)
    }
}

struct FXValueMetadata: Codable {
    let requestedCacheKeyPaths: [String]!

    var creationDate: String? = ISO8601DateFormatter().string(from: Date())

    init(requestedCacheKeyPaths: [String]) {
        self.requestedCacheKeyPaths = requestedCacheKeyPaths.sorted()
    }
}

final class InternalValue<V: FXValue>: LLBValue {
    let value: V
    let metadata: FXValueMetadata

    convenience init(_ value: V, requestedCacheKeyPaths: [String]) {
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

extension InternalValue: LLBCASObjectRepresentable {
    func asCASObject() throws -> LLBCASObject {
        let codable = CodableInternalValue(value, metadata: metadata)
        let data = try FXEncoder().encode(codable)
        let buffer = LLBByteBufferAllocator().buffer(bytes: ArraySlice<UInt8>(data))
        return LLBCASObject(refs: value.refs, data: buffer)
    }
}

extension InternalValue: LLBCASObjectConstructable {
    convenience init(from casObject: LLBCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let codable = try FXDecoder().decode(CodableInternalValue<V>.self, from: data)
        let value = try V(refs: casObject.refs, codableValue: codable.value)
        self.init(value, metadata: codable.metadata)
    }
}
