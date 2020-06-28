// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCBasic
import TSCUtility
import LLBCAS

/// CAS backed FileSystem implementation rooted at the given CASTree.
///
/// NOTE:- This class should *NOT* be used inside the db's NIO event loop.
public final class TSCCASFileSystem: FileSystem {

    let rootTree: LLBCASFileTree
    let db: LLBCASDatabase
    let client: LLBCASFSClient
    let ctx: Context

    public init(
        db: LLBCASDatabase,
        rootTree: LLBCASFileTree,
        _ ctx: Context
    ) {
        self.db = db
        self.client = LLBCASFSClient(db)
        self.rootTree = rootTree
        self.ctx = ctx
    }

    public func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
        if path.isRoot {
            return true
        }
        let result = try? self.rootTree.lookup(path: path, in: self.db, Context()).wait()
        return result != nil
    }

    public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        if path.isRoot {
            return rootTree.files.map { $0.name }
        }

        let _result = try self.rootTree.lookup(path: path, in: self.db, ctx).wait()
        guard let result = _result else { throw FileSystemError.noEntry }

        // HACK: If this is a symlink, check if it points to a directory.
        // Move this to LLBCASFileTree.lookup()
        if result.info.type == .symlink, isDirectory(path) {
            let symlinkContents = try readFileContents(path).cString
            return try getDirectoryContents(path.parentDirectory.appending(RelativePath(symlinkContents)))
        }

        let entry = try self.client.load(result.id, ctx).wait()
        guard let tree = entry.tree else { throw FileSystemError.notDirectory }
        return tree.files.map{ $0.name }
    }

    public func isDirectory(_ path: AbsolutePath) -> Bool {
        let fileType = self.fileType(of: path)
        if fileType == .directory {
            return true
        }

        // HACK: If this is a symlink, check if it points to a directory.
        // Move this to LLBCASFileTree.lookup()
        if fileType == .symlink {
            guard let symlinkContents = try? readFileContents(path).cString else {
                return false
            }
            return isDirectory(path.parentDirectory.appending(RelativePath(symlinkContents)))
        }

        return false
    }

    private func fileType(of path: AbsolutePath) -> LLBFileType? {
        if path.isRoot { return .directory }
        let fileType = try? self.rootTree.lookup(path: path, in: self.db, ctx).wait()
        return fileType?.info.type
    }

    public func isFile(_ path: AbsolutePath) -> Bool {
        let fileType = self.fileType(of: path)
        return fileType == .plainFile || fileType == .executable
    }

    public func isExecutableFile(_ path: AbsolutePath) -> Bool {
        fileType(of: path) == .executable
    }

    public func isSymlink(_ path: AbsolutePath) -> Bool {
        fileType(of: path) == .symlink
    }

    public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        if path.isRoot {
            throw FileSystemError.ioError
        }

        let result = try rootTree.lookup(path: path, in: db, ctx).wait()
        guard let id = result?.id else { throw FileSystemError.noEntry }

        let entry = try client.load(id, ctx).wait()
        guard let blob = entry.blob else { throw FileSystemError.ioError }
        let bytes = try blob.read(ctx).wait()
        return ByteString(bytes)
    }

    public func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
        throw FileSystemError.unsupported
    }

    public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        throw FileSystemError.unsupported
    }

    public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        throw FileSystemError.unsupported
    }

    public func removeFileTree(_ path: AbsolutePath) throws {
        throw FileSystemError.unsupported
    }

    public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        throw FileSystemError.unsupported
    }

    public func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        throw FileSystemError.unsupported
    }

    public var currentWorkingDirectory: AbsolutePath? { nil }

    public func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
        throw FileSystemError.unsupported
    }

    public var homeDirectory: AbsolutePath { .root }
}
