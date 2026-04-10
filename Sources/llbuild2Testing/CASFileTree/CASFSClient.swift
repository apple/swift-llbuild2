// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import Foundation
import NIOCore
import TSCBasic
import TSCUtility

/// A main API struct
package struct FXCASFSClient: Sendable {
    package let db: any FXCASDatabase

    /// Errors produced by CASClient
    package enum Error: Swift.Error {
        case noEntry(FXDataID)
        case notSupportedYet
        case invalidUse
        case unexpectedNode
    }

    /// Remembers db
    package init(_ db: any FXCASDatabase) {
        self.db = db
    }

    /// Check that DataID exists in CAS
    package func exists(_ id: FXDataID, _ ctx: Context) -> FXFuture<Bool> {
        return db.contains(id, ctx)
    }

    /// Load CASFSNode from CAS
    /// If object doesn't exist future fails with noEntry
    package func load(_ id: FXDataID, type hint: FXFileType? = nil, _ ctx: Context) -> FXFuture<
        FXCASFSNode
    > {
        return db.get(id, ctx).flatMapThrowing { objectOpt in
            guard let object = objectOpt else {
                throw Error.noEntry(id)
            }

            switch hint {
            case .directory?:
                let tree = try FXCASFileTree(id: id, object: object)
                return FXCASFSNode(tree: tree, db: self.db)
            case .plainFile?, .executable?:
                let blob = try FXCASBlob(db: self.db, id: id, type: hint!, object: object, ctx)
                return FXCASFSNode(blob: blob, db: self.db)
            case .symlink?, .UNRECOGNIZED?:
                // We don't support symlinks yet
                throw Error.notSupportedYet
            case nil:
                if let tree = try? FXCASFileTree(id: id, object: object) {
                    return FXCASFSNode(tree: tree, db: self.db)
                } else if let blob = try? FXCASBlob(db: self.db, id: id, object: object, ctx) {
                    return FXCASFSNode(blob: blob, db: self.db)
                } else {
                    // We don't support symlinks yet
                    throw Error.notSupportedYet
                }
            }
        }
    }

    /// Save ByteBuffer to CAS
    package func store(_ data: FXByteBuffer, type: FXFileType = .plainFile, _ ctx: Context)
        -> FXFuture<FXCASFSNode>
    {
        FXCASBlob.import(data: data, isExecutable: type == .executable, in: db, ctx).map {
            FXCASFSNode(blob: $0, db: self.db)
        }
    }

    /// Save ArraySlice to CAS
    package func store(_ data: ArraySlice<UInt8>, type: FXFileType = .plainFile, _ ctx: Context)
        -> FXFuture<FXCASFSNode>
    {
        FXCASBlob.import(
            data: FXByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx
        ).map { FXCASFSNode(blob: $0, db: self.db) }
    }

    /// Save Data to CAS
    package func store(_ data: Data, type: FXFileType = .plainFile, _ ctx: Context) -> FXFuture<
        FXCASFSNode
    > {
        FXCASBlob.import(
            data: FXByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx
        ).map { FXCASFSNode(blob: $0, db: self.db) }
    }

}

extension FXCASFSClient {
    package func store(_ data: FXByteBuffer, type: FXFileType = .plainFile, _ ctx: Context)
        -> FXFuture<FXDataID>
    {
        FXCASBlob.import(data: data, isExecutable: type == .executable, in: db, ctx).flatMap {
            $0.export(ctx)
        }
    }

    package func store(_ data: ArraySlice<UInt8>, type: FXFileType = .plainFile, _ ctx: Context)
        -> FXFuture<FXDataID>
    {
        FXCASBlob.import(
            data: FXByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx
        ).flatMap { $0.export(ctx) }
    }

    package func store(_ data: Data, type: FXFileType = .plainFile, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        FXCASBlob.import(
            data: FXByteBuffer.withBytes(data), isExecutable: type == .executable, in: db, ctx
        ).flatMap { $0.export(ctx) }
    }
}

extension FXCASFSClient {
    /// Creates a new FXCASFileTree node by prepending the tree with the given graph. For example, if the given id
    /// contains a reference to a CASFileTree containing [a.txt, b.txt], and path was 'some/path', the resulting
    /// CASFileTree would contain [some/path/a.txt, some/path/b.txt] (where both `some` and `path` represent
    /// CASFileTrees).
    package func wrap(_ id: FXDataID, path: String, _ ctx: Context) -> FXFuture<FXCASFileTree> {
        let absolutePath: AbsolutePath
        do {
            absolutePath = try AbsolutePath(validating: path, relativeTo: .root)
        } catch {
            return ctx.group.any().makeFailedFuture(error)
        }
        return self.load(id, ctx).flatMap { node in
            return absolutePath
                .components
                .dropFirst()
                .reversed()
                .reduce(self.db.group.next().makeSucceededFuture(node)) { future, pathComponent in
                    future.flatMap { node in
                        let entry = node.asDirectoryEntry(filename: pathComponent)
                        return FXCASFileTree.create(files: [entry], in: self.db, ctx).map {
                            return FXCASFSNode(tree: $0, db: self.db)
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
