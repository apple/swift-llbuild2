// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import LLBCAS
import LLBSupport


/// A main API struct
public struct LLBCASFSClient {
    public let db: LLBCASDatabase

    /// Errors produced by CASClient
    public enum Error: Swift.Error {
        case noEntry(LLBDataID)
        case notSupportedYet
        case invalidUse
    }

    /// Remembers db
    public init(_ db: LLBCASDatabase) {
        self.db = db
    }

    /// Check that DataID exists in CAS
    public func exists(_ id: LLBDataID) -> LLBFuture<Bool> {
        return db.contains(id)
    }

    /// Load CASFSNode from CAS
    /// If object doesn't exist future fails with noEntry
    public func load(_ id: LLBDataID, type hint: LLBFileType? = nil) -> LLBFuture<LLBCASFSNode> {
        return db.get(id).flatMapThrowing { objectOpt in
            guard let object = objectOpt else {
                throw Error.noEntry(id)
            }

            switch hint {
            case .directory?:
                let tree = try LLBCASFileTree(id: id, object: object)
                return LLBCASFSNode(tree: tree, db: self.db)
            case .plainFile?, .executable?:
                let blob = try LLBCASBlob(db: self.db, id: id, type: hint!, object: object)
                return LLBCASFSNode(blob: blob, db: self.db)
            case .symlink?, .UNRECOGNIZED?:
                // We don't support symlinks yet
                throw Error.notSupportedYet
            case nil:
                if let tree = try? LLBCASFileTree(id: id, object: object) {
                    return LLBCASFSNode(tree: tree, db: self.db)
                } else if let blob = try? LLBCASBlob(db: self.db, id: id, object: object) {
                    return LLBCASFSNode(blob: blob, db: self.db)
                } else {
                    // We don't support symlinks yet
                    throw Error.notSupportedYet
                }
            }
        }
    }

    /// Save ByteBuffer to CAS
    public func store(_ data: LLBByteBuffer, type: LLBFileType = .plainFile) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: data, isExecutable: type == .executable, in: db).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

    /// Save ArraySlice to CAS
    public func store(_ data: ArraySlice<UInt8>, type: LLBFileType = .plainFile) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(data), isExecutable: type == .executable, in: db).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

    /// Save Data to CAS
    public func store(_ data: Data, type: LLBFileType = .plainFile) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(data)), isExecutable: type == .executable, in: db).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

}

extension LLBCASFSClient {
    public func store(_ data: LLBByteBuffer, type: LLBFileType = .plainFile) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: data, isExecutable: type == .executable, in: db).flatMap { $0.export() }
    }

    public func store(_ data: ArraySlice<UInt8>, type: LLBFileType = .plainFile) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(data), isExecutable: type == .executable, in: db).flatMap { $0.export() }
    }

    public func store(_ data: Data, type: LLBFileType = .plainFile) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(data)), isExecutable: type == .executable, in: db).flatMap { $0.export() }
    }
}
