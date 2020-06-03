// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic

import LLBSupport


public protocol LLBFilesystemObjectMaterializer: class {
    func materialize(object: LLBFilesystemObject) throws
}

/// A non-recursive representation of a filesystem object or its part.
public struct LLBFilesystemObject {
    public let path: AbsolutePath
    public let content: Content
    public let permissions: mode_t?

    public enum Content {
    /// Not an actual filesystem content, a placeholder.
    case ignore
    /// Create an empty file.
    case empty(size: UInt64, executable: Bool)
    /// Part of a file to be placed at a specified offset.
    case partial(data: LLBFastData, offset: UInt64)
    /// An entire file (possibly executable)
    case file(data: LLBFastData, executable: Bool)
    /// Symbolic link.
    case symlink(target: String)
    /// An (empty) directory.
    case directory
    }

    public init() {
        self.path = AbsolutePath("/")
        self.content = Content.ignore
        self.permissions = nil
    }

    public init(_ path: AbsolutePath, _ content: Content, permissions: mode_t? = nil) {
        self.path = path
        self.content = content
        self.permissions = permissions
    }
}


/// Expose accounting stats.
extension LLBFilesystemObject {

    // Number of bytes represented by this FilesystemObject.
    var accountedDataSize: Int {
        switch self.content {
        case .ignore, .empty:
            return 0
        case let .partial(data, _):
            return data.count
        case let .file(data, _):
            return data.count
        case let .symlink(target):
            return target.utf8.count
        case .directory:
            return 0
        }
    }

    // Number of objects represented by this FilesystemObject.
    var accountedObjects: Int {
        switch content {
        case .ignore, .partial:
            return 0
        default:
            return 1
        }
    }

}

/// A way to put objects to the real filesystem.
public final class LLBRealFilesystemMaterializer: LLBFilesystemObjectMaterializer {

    public init() { }

    public func materialize(object: LLBFilesystemObject) throws {
        let path = object.path

        switch object.content {
        case .ignore:
            // Nothing to do
            break
        case let .empty(size, executable):

            // Be mindful and rely on `umask` when setting permissions.
            let perms = object.permissions ?? (executable ? 0o777 : 0o666)

            let fd = open(path.pathString, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, perms)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            if size > 0 && ftruncate(fd, off_t(size)) == -1 {
                throw LLBExportIOError.unableSyscall(path: path, call: "ftruncate", error: String(cString: strerror(errno)))
            }

            // If permissions are explicitly specified, `umask` could have
            // broken the desired permissions.
            // Fix it here before we start writing (exposing) the data.
            if let perms = object.permissions {
                guard fchmod(fd, perms) != -1 else {
                    throw LLBExportIOError.unableSyscall(path: object.path, call: "fchmod", error: String(cString: strerror(errno)))
                }
            }

        case let .partial(data, fileOffset):
            // The file should exist by now. Insert data into it.

            let fd = open(path.pathString, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            try writeFileData(fd: fd, data: data, startOffset: fileOffset, debugPath: path)

        case let .file(data, executable):

            // Be mindful and rely on `umask` when setting permissions.
            let perms = object.permissions ?? (executable ? 0o777 : 0o666)

            let fd = open(path.pathString, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, perms)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            // If permissions are explicitly specified, `umask` could have
            // broken the desired permissions.
            // Fix it here before we start writing (exposing) the data.
            if let perms = object.permissions {
                guard fchmod(fd, perms) != -1 else {
                    throw LLBExportIOError.unableSyscall(path: object.path, call: "fchmod", error: String(cString: strerror(errno)))
                }
            }

            try writeFileData(fd: fd, data: data, startOffset: 0, debugPath: path)

        case let .symlink(target):

            let pathString = path.pathString
            if symlink(target, pathString) != 0 {
                // Try removing the path, in case it existed.
                unlink(pathString)
                if symlink(target, pathString) != 0 {
                    throw LLBExportIOError.unableToSymlink(path: path, target: target)
                }
            }

        case .directory:
            // Create the directory.
            try TSCBasic.localFileSystem.createDirectory(path)
        }
    }

    /// Can't use Basic's file utilities without data conversion.
    /// Instead we implement a low level write loop.
    private func writeFileData(fd: CInt, data: LLBFastData, startOffset: UInt64, debugPath: AbsolutePath) throws {
        var dataOffset: Int = 0
        repeat {
            let (uint_off, overflow) = startOffset.addingReportingOverflow(UInt64(dataOffset))
            guard let file_offset = off_t(exactly: uint_off), !overflow else {
                throw LLBExportIOError.unableSyscall(path: debugPath, call: "pwrite", error: String(cString: strerror(ERANGE)))
            }

            let err: CInt = data.withContiguousStorage { ptr in
                let ret = pwrite(fd, ptr.baseAddress!.advanced(by: dataOffset), ptr.count - dataOffset, file_offset)
                if ret == -1 {
                    return errno
                } else {
                    dataOffset += ret
                    return 0
                }
            }
            guard err == 0 || err == EINTR else {
                throw LLBExportIOError.unableSyscall(path: debugPath, call: "pwrite", error: String(cString: strerror(err)))
            }
        } while dataOffset < data.count
    }
}
