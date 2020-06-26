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
import TSCBasic
import TSCUtility


/// A main API struct
public struct LLBCASFSClient {
    public let db: LLBCASDatabase

    /// Errors produced by CASClient
    public enum Error: Swift.Error {
        case noEntry(LLBDataID)
        case notSupportedYet
        case invalidUse
        case unexpectedNode
    }

    /// Remembers db
    public init(_ db: LLBCASDatabase) {
        self.db = db
    }

    /// Check that DataID exists in CAS
    public func exists(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<Bool> {
        return db.contains(id, ctx)
    }

    /// Load CASFSNode from CAS
    /// If object doesn't exist future fails with noEntry
    public func load(_ id: LLBDataID, type hint: LLBFileType? = nil, _ ctx: Context) -> LLBFuture<LLBCASFSNode> {
        return db.get(id, ctx).flatMapThrowing { objectOpt in
            guard let object = objectOpt else {
                throw Error.noEntry(id)
            }

            switch hint {
            case .directory?:
                let tree = try LLBCASFileTree(id: id, object: object)
                return LLBCASFSNode(tree: tree, db: self.db)
            case .plainFile?, .executable?:
                let blob = try LLBCASBlob(db: self.db, id: id, type: hint!, object: object, ctx)
                return LLBCASFSNode(blob: blob, db: self.db)
            case .symlink?, .UNRECOGNIZED?:
                // We don't support symlinks yet
                throw Error.notSupportedYet
            case nil:
                if let tree = try? LLBCASFileTree(id: id, object: object) {
                    return LLBCASFSNode(tree: tree, db: self.db)
                } else if let blob = try? LLBCASBlob(db: self.db, id: id, object: object, ctx) {
                    return LLBCASFSNode(blob: blob, db: self.db)
                } else {
                    // We don't support symlinks yet
                    throw Error.notSupportedYet
                }
            }
        }
    }

    /// Save ByteBuffer to CAS
    public func store(_ data: LLBByteBuffer, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: data, isExecutable: type == .executable, in: db, ctx).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

    /// Save ArraySlice to CAS
    public func store(_ data: ArraySlice<UInt8>, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

    /// Save Data to CAS
    public func store(_ data: Data, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBCASFSNode> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(data)), isExecutable: type == .executable, in: db, ctx).map { LLBCASFSNode(blob: $0, db: self.db) }
    }

}

extension LLBCASFSClient {
    public func store(_ data: LLBByteBuffer, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: data, isExecutable: type == .executable, in: db, ctx).flatMap { $0.export(ctx) }
    }

    public func store(_ data: ArraySlice<UInt8>, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx).flatMap { $0.export(ctx) }
    }

    public func store(_ data: Data, type: LLBFileType = .plainFile, _ ctx: Context) -> LLBFuture<LLBDataID> {
        LLBCASBlob.import(data: LLBByteBuffer.withBytes(ArraySlice<UInt8>(data)), isExecutable: type == .executable, in: db, ctx).flatMap { $0.export(ctx) }
    }
}

extension LLBCASFSClient {
    /// Creates a new LLBCASFileTree node by prepending the tree with the given graph. For example, if the given id
    /// contains a reference to a CASFileTree containing [a.txt, b.txt], and path was 'some/path', the resulting
    /// CASFileTree would contain [some/path/a.txt, some/path/b.txt] (where both `some` and `path` represent
    /// CASFileTrees).
    public func wrap(_ id: LLBDataID, path: String, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        return self.load(id, ctx).flatMap { node in
            return AbsolutePath(path, relativeTo: .root)
                .components
                .dropFirst()
                .reversed()
                .reduce(self.db.group.next().makeSucceededFuture(node)) { future, pathComponent in
                    future.flatMap { node in
                        let entry = node.asDirectoryEntry(filename: pathComponent)
                        return LLBCASFileTree.create(files: [entry], in: self.db, ctx).map {
                            return LLBCASFSNode(tree: $0, db: self.db)
                        }
                    }
                }
        }.flatMapThrowing {
            guard let tree = $0.tree else {
                throw Error.unexpectedNode
            }
            return tree
        }
    }
}
