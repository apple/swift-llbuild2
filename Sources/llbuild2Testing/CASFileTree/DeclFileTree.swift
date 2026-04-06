// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import NIOCore
import TSCUtility

/// A declarative way to create a CASFileTree with content known upfront
/// Usage example:
/// let tree: LLBDeclFileTree = .dir(["dir1": .dir([<dir1 content>]), "file1": .file(<file1 content>)])
/// let casTreeFuture = tree.toTree(db: db)
package indirect enum LLBDeclFileTree {
    case directory(files: [String: LLBDeclFileTree])
    case file(contents: [UInt8])

    package static func dir(_ files: [String: LLBDeclFileTree]) -> LLBDeclFileTree {
        return .directory(files: files)
    }

    package static func file(_ contents: [UInt8]) -> LLBDeclFileTree {
        return .file(contents: contents)
    }

    package static func file(_ contents: String) -> LLBDeclFileTree {
        return .file(contents: Array(contents.utf8))
    }
}

extension LLBDeclFileTree: CustomDebugStringConvertible {
    package var debugDescription: String {
        switch self {
        case .directory(let files):
            return ".directory(\(files))"
        case .file(let contents):
            return ".file(\(contents.count))"
        }
    }
}

extension FXCASFSClient {
    /// Save LLBDeclFileTree to CAS
    package func store(_ declTree: LLBDeclFileTree, _ ctx: Context) -> FXFuture<FXCASFSNode> {
        switch declTree {
        case .directory:
            return storeDir(declTree, ctx).map { FXCASFSNode(tree: $0, db: self.db) }
        case .file:
            return storeFile(declTree, ctx).map { FXCASFSNode(blob: $0, db: self.db) }
        }
    }

    package func storeDir(_ declTree: LLBDeclFileTree, _ ctx: Context) -> FXFuture<FXCASFileTree> {
        let loop = db.group.next()
        guard case .directory(files: let files) = declTree else {
            return loop.makeFailedFuture(Error.invalidUse)
        }
        let infosFutures: [FXFuture<LLBDirectoryEntryID>] = files.map { arg in
            let (key, value) = arg
            switch value {
            case .directory:
                let treeFuture = storeDir(value, ctx)
                return treeFuture.map { tree in
                    LLBDirectoryEntryID(
                        info: .init(name: key, type: .directory, size: tree.aggregateSize),
                        id: tree.id)
                }
            case .file(_):
                return storeFile(value, ctx).map { blob in
                    blob.asDirectoryEntry(filename: key)
                }
            }
        }
        return FXFuture.whenAllSucceed(infosFutures, on: loop).flatMap { infos in
            return FXCASFileTree.create(files: infos, in: self.db, ctx)
        }
    }

    package func storeFile(_ declTree: LLBDeclFileTree, _ ctx: Context) -> FXFuture<FXCASBlob> {
        let loop = db.group.next()
        guard case .file(contents: let contents) = declTree else {
            return loop.makeFailedFuture(Error.invalidUse)
        }
        return FXCASBlob.import(
            data: FXByteBuffer.withBytes(contents), isExecutable: false, in: db, ctx)
    }

}

extension FXCASFSClient {
    package func store(_ declTree: LLBDeclFileTree, _ ctx: Context) -> FXFuture<FXDataID> {
        switch declTree {
        case .directory:
            return storeDir(declTree, ctx).map { $0.id }
        case .file:
            return storeFile(declTree, ctx).flatMap { casBlob in
                casBlob.export(ctx)
            }
        }
    }
}
