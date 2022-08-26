// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSFCAS
import llbuild2

public protocol FXWrappedDataID {
    var dataID: LLBDataID { get }
}

public protocol FXSingleDataIDValue: FXValue, FXWrappedDataID, Encodable, Hashable, Comparable {
    init(dataID: LLBDataID)
}

public protocol FXThinEncodedSingleDataIDValue: FXSingleDataIDValue {

}

extension FXSingleDataIDValue {
    public init(_ dataID: LLBDataID) {
        self = Self(dataID: dataID)
    }
}

public struct FXNullCodableValue: Codable {}

extension FXSingleDataIDValue {
    public var refs: [LLBDataID] { [dataID] }
    public var codableValue: FXNullCodableValue { FXNullCodableValue() }
    public init(refs: [LLBDataID], codableValue: FXNullCodableValue) {
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

enum WrappedDataIDError: Swift.Error {
    case noRefs
    case wrongNodeType(id: LLBDataID, expected: LLBFileType, actual: LLBFileType)
}

extension FXSingleDataIDValue {
    public init(from casObject: LLBCASObject) throws {
        let refs = casObject.refs
        guard !refs.isEmpty else {
            throw WrappedDataIDError.noRefs
        }

        let dataID = refs[0]

        self = Self(dataID)
    }
}

extension FXSingleDataIDValue {
    public func asCASObject() throws -> LLBCASObject {
        LLBCASObject(refs: [dataID], data: LLBByteBuffer())
    }
}

public protocol FXNodeID: FXWrappedDataID {
    func load(_ ctx: Context) -> LLBFuture<LLBCASFSNode>
}

extension FXNodeID {
    public func load(_ ctx: Context) -> LLBFuture<LLBCASFSNode> {
        let client = LLBCASFSClient(ctx.db)
        return client.load(self.dataID, ctx)
    }
}

public protocol FXTreeID: FXNodeID {
    func load(_ ctx: Context) -> LLBFuture<LLBCASFileTree>
}

extension FXTreeID {
    public func load(_ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        let client = LLBCASFSClient(ctx.db)
        let dataID = self.dataID
        return client.load(dataID, type: .directory, ctx).flatMapThrowing { node in
            let type = node.type()
            guard type == .directory else {
                throw WrappedDataIDError.wrongNodeType(id: dataID, expected: .directory, actual: type)
            }

            return node.tree!
        }
    }
}

public protocol FXFileID: FXNodeID {
    func load(_ ctx: Context) -> LLBFuture<LLBCASBlob>
}

extension FXFileID {
    public func load(_ ctx: Context) -> LLBFuture<LLBCASBlob> {
        let client = LLBCASFSClient(ctx.db)
        let dataID = self.dataID
        return client.load(dataID, type: .plainFile, ctx).flatMapThrowing { node in
            let type = node.type()
            guard type == .plainFile else {
                throw WrappedDataIDError.wrongNodeType(id: dataID, expected: .plainFile, actual: type)
            }

            return node.blob!
        }
    }
}

public protocol FXExecutableFileID: FXNodeID {
    func load(_ ctx: Context) -> LLBFuture<LLBCASBlob>
}

extension FXExecutableFileID {
    public func load(_ ctx: Context) -> LLBFuture<LLBCASBlob> {
        let client = LLBCASFSClient(ctx.db)
        let dataID = self.dataID
        return client.load(dataID, type: .executable, ctx).flatMapThrowing { node in
            let type = node.type()
            guard type == .executable else {
                throw WrappedDataIDError.wrongNodeType(id: dataID, expected: .executable, actual: type)
            }

            return node.blob!
        }
    }
}
