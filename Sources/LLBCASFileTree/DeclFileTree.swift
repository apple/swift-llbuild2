// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBCAS
import LLBSupport


/// A declarative way to create a CASFileTree with content known upfront
/// Usage example:
/// let tree: LLBDeclFileTree = .dir(["dir1": .dir([<dir1 content>]), "file1": .file(<file1 content>)])
/// let casTreeFuture = tree.toTree(db: db)
public indirect enum LLBDeclFileTree {
    case directory(files: [String: LLBDeclFileTree])
    case file(contents: [UInt8])

    public static func dir(_ files: [String: LLBDeclFileTree]) -> LLBDeclFileTree {
        return .directory(files: files)
    }

    public static func file(_ contents: [UInt8]) -> LLBDeclFileTree {
        return .file(contents: contents)
    }

    public static func file(_ contents: String) -> LLBDeclFileTree {
        return .file(contents: Array(contents.utf8))
    }
}

extension LLBDeclFileTree: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .directory(files):
            return ".directory(\(files))"
        case let .file(contents):
            return ".file(\(contents.count))"
        }
    }
}


extension LLBCASFSClient {
    /// Save LLBDeclFileTree to CAS
    public func store(_ declTree: LLBDeclFileTree) -> LLBFuture<LLBCASFSNode> {
        switch declTree {
            case .directory:
                return storeDir(declTree).map { LLBCASFSNode(tree: $0, db: self.db) }
            case .file:
                return storeFile(declTree).map { LLBCASFSNode(blob: $0, db: self.db) }
        }
    }

    public func storeDir(_ declTree: LLBDeclFileTree) -> LLBFuture<LLBCASFileTree> {
        let loop = db.group.next()
        guard case .directory(files: let files) = declTree else {
            return loop.makeFailedFuture(Error.invalidUse)
        }
        let infosFutures: [LLBFuture<LLBDirectoryEntryID>] = files.map { arg in
            let (key, value) = arg
            switch value {
                case .directory:
                    let treeFuture = storeDir(value)
                    return treeFuture.map { tree in
                        LLBDirectoryEntryID(info: .init(name: key, type: .directory, size: tree.aggregateSize),
                                              id: tree.id)}
                case .file(_):
                    return storeFile(value).map { blob in
                        blob.asDirectoryEntry(filename: key)
                }
            }
        }
        return LLBFuture.whenAllSucceed(infosFutures, on: loop).flatMap { infos in
            return LLBCASFileTree.create(files: infos, in: self.db)
        }
    }

    public func storeFile(_ declTree: LLBDeclFileTree) -> LLBFuture<LLBCASBlob> {
        let loop = db.group.next()
        guard case .file(contents: let contents) = declTree else {
            return loop.makeFailedFuture(Error.invalidUse)
        }
        return LLBCASBlob.import(data: LLBByteBuffer.withBytes(ArraySlice(contents)), isExecutable: false,
                              in: db)
    }

}

extension LLBCASFSClient {
    public func store(_ declTree: LLBDeclFileTree) -> LLBFuture<LLBDataID> {
        switch declTree {
            case .directory:
                return storeDir(declTree).map{ $0.id }
            case .file:
                return storeFile(declTree).flatMap { casBlob in
                    casBlob.export()
            }
        }
    }
}
