// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

public protocol FXWrappedDataID: Sendable {
    associatedtype DataID: FXDataIDProtocol = FXDataID
    var dataID: DataID { get }
}

public protocol FXSingleDataIDValue: FXValue, FXWrappedDataID, Encodable, Hashable, Comparable {
    init(dataID: DataID)
}

public protocol FXThinEncodedSingleDataIDValue: FXSingleDataIDValue {

}

extension FXSingleDataIDValue {
    public init(_ dataID: DataID) {
        self = Self(dataID: dataID)
    }
}

public struct FXNullCodableValue: Codable {}

extension FXSingleDataIDValue {
    public var refs: [DataID] { [dataID] }
    public var codableValue: FXNullCodableValue { FXNullCodableValue() }
    public init(refs: [DataID], codableValue: FXNullCodableValue) {
        self.init(refs[0])
    }
}

extension FXSingleDataIDValue {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.dataID < rhs.dataID
    }
}

extension FXSingleDataIDValue {
    public func encode(to encoder: Encoder) throws {
        try encoder.encodeHash(of: ArraySlice<UInt8>(dataID.bytes))
    }
}

extension FXThinEncodedSingleDataIDValue {
    public func encode(to encoder: Encoder) throws {
        // Since we already have a hash value, directly encode a short prefix of it
        var container = encoder.singleValueContainer()
        let str = ArraySlice(dataID.bytes.dropFirst().prefix(9)).base64URL()
        try container.encode(str)
    }
}

package enum WrappedDataIDError: Swift.Error {
    case noRefs
}

extension FXSingleDataIDValue where DataID == FXDataID {
    public init(from casObject: FXCASObject) throws {
        let refs = casObject.refs
        guard !refs.isEmpty else {
            throw WrappedDataIDError.noRefs
        }

        let dataID = refs[0]

        self = Self(dataID)
    }
}

extension FXSingleDataIDValue where DataID == FXDataID {
    public func asCASObject() throws -> FXCASObject {
        FXCASObject(refs: [dataID], data: FXByteBuffer())
    }
}

extension FXSingleDataIDValue {
    public init<O: FXCASObjectProtocol>(from casObject: O) throws where O.DataID == DataID {
        let refs = casObject.refs
        guard !refs.isEmpty else {
            throw WrappedDataIDError.noRefs
        }

        let dataID = refs[0]

        self = Self(dataID)
    }

    public func asCASObject<O: FXCASObjectProtocol>() throws -> O where O.DataID == DataID {
        O(refs: [dataID], data: FXByteBuffer())
    }
}

public protocol FXNodeID: FXWrappedDataID {
}

public protocol FXTreeID: FXNodeID {
}

public protocol FXFileID: FXNodeID {
}

public protocol FXExecutableFileID: FXNodeID {
}
