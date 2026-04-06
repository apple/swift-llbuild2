// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import Foundation
import TSCBasic

package protocol LLBFilesystemObjectMaterializer: AnyObject {
    func materialize(object: LLBFilesystemObject) throws
}

/// A non-recursive representation of a filesystem object or its part.
package struct LLBFilesystemObject {
    package let path: AbsolutePath
    package let content: Content
    package let posixDetails: LLBPosixFileDetails?

    package enum Content {
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

    package init() {
        self.path = AbsolutePath.root
        self.content = Content.ignore
        self.posixDetails = nil
    }

    package init(_ path: AbsolutePath, _ content: Content, posixDetails: LLBPosixFileDetails? = nil)
    {
        self.path = path
        self.content = content
        self.posixDetails = posixDetails
    }
}

/// Expose accounting stats.
extension LLBFilesystemObject {

    // Number of bytes represented by this LLBFilesystemObject.
    var accountedDataSize: Int {
        switch self.content {
        case .ignore, .empty:
            return 0
        case .partial(let data, _):
            return data.count
        case .file(let data, _):
            return data.count
        case .symlink(let target):
            return target.utf8.count
        case .directory:
            return 0
        }
    }

    // Number of objects represented by this LLBFilesystemObject.
    var accountedObjects: Int {
        switch content {
        case .ignore, .partial:
            return 0
        default:
            return 1
        }
    }

}

extension LLBPosixFileDetails {
    init(from info: stat) {
        self = LLBPosixFileDetails()
        mode = UInt32(exactly: info.st_mode & 0o7777) ?? 0
        owner = UInt32(exactly: info.st_uid) ?? 0
        group = UInt32(exactly: info.st_gid) ?? 0
    }

    init?(from info: LLBFileInfo) {
        guard info.hasPosixDetails else {
            return nil
        }
        var posixDetails = info.posixDetails
        posixDetails.mode &= 0o7777
        self = posixDetails
    }

    init?(from info: LLBDirectoryEntry) {
        guard info.hasPosixDetails else {
            return nil
        }
        var posixDetails = info.posixDetails
        posixDetails.mode &= 0o7777
        self = posixDetails
    }
}

/// A way to put objects to the real filesystem.
package final class LLBRealFilesystemMaterializer: LLBFilesystemObjectMaterializer {

    private let userIsSuperuser: Bool
    private let preserve: FXCASFileTree.PreservePosixDetails

    package init(preservePosixDetails: FXCASFileTree.PreservePosixDetails = .init()) {
        self.userIsSuperuser = geteuid() == 0
        self.preserve = preservePosixDetails
    }

    package func materialize(object: LLBFilesystemObject) throws {
        let path = object.path

        switch object.content {
        case .ignore:
            // Nothing to do
            break
        case .empty(let size, let executable):

            // Be mindful and rely on `umask` when setting permissions.
            let openMode: mode_t
            if let pd = object.posixDetails, let mode = mode_t(exactly: pd.mode), mode != 0 {
                openMode = mode
            } else {
                openMode = (executable ? 0o755 : 0o644)
            }

            let fd = open(path.pathString, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, openMode)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(
                    path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            if size > 0 && ftruncate(fd, off_t(size)) == -1 {
                throw LLBExportIOError.unableSyscall(
                    path: path, call: "ftruncate", error: String(cString: strerror(errno)))
            }

            try updateFileDetails(object: object, fd: fd)

        case .partial(let data, let fileOffset):
            // The file should exist by now. Insert data into it.

            let fd = open(path.pathString, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(
                    path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            try writeFileData(fd: fd, data: data, startOffset: fileOffset, debugPath: path)

        case .file(let data, let executable):

            // Be mindful and rely on `umask` when setting permissions.
            let openMode: mode_t
            if let pd = object.posixDetails, let mode = mode_t(exactly: pd.mode), mode != 0 {
                openMode = mode
            } else {
                openMode = (executable ? 0o755 : 0o644)
            }

            let fd = open(
                path.pathString, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, openMode)
            guard fd != -1 else {
                throw LLBExportIOError.unableSyscall(
                    path: path, call: "open", error: String(cString: strerror(errno)))
            }
            defer { close(fd) }

            try updateFileDetails(object: object, fd: fd)

            try writeFileData(fd: fd, data: data, startOffset: 0, debugPath: path)

        case .symlink(let target):

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

            guard object.posixDetails?.normalized(expectedMode: 0o755, options: nil) != nil else {
                break
            }

            if let dir = opendir(path.pathString) {
                defer { closedir(dir) }
                try updateFileDetails(object: object, fd: dirfd(dir))
            } else {
                throw LLBExportIOError.unableSyscall(
                    path: object.path, call: "fdopen", error: String(cString: strerror(errno)))
            }
        }
    }

    private func updateFileDetails(object: LLBFilesystemObject, fd: CInt) throws {

        let expectedMode: mode_t
        switch object.content {
        case .ignore, .symlink, .partial:
            return
        case .empty(_, let executable),
            .file(_, let executable):
            expectedMode = executable ? 0o755 : 0o644
        case .directory:
            expectedMode = 0o755
        }

        guard
            let details = object.posixDetails?.normalized(expectedMode: expectedMode, options: nil)
        else {
            return
        }

        if userIsSuperuser, preserve.preservePosixOwnership {
            let owner = uid_t(exactly: details.owner) ?? 0
            let group = gid_t(exactly: details.group) ?? 0
            if owner != 0 || group != 0 {
                guard fchown(fd, owner, group) != -1 else {
                    throw LLBExportIOError.unableSyscall(
                        path: object.path, call: "fchown", error: String(cString: strerror(errno)))
                }
            }
        }

        // If permissions are explicitly specified, `umask` could have
        // broken the desired permissions.
        // Fix it here before we start writing (exposing) the data.
        if preserve.preservePosixMode, let mode = mode_t(exactly: details.mode), mode != 0 {
            guard fchmod(fd, mode & 0o7777) != -1 else {
                throw LLBExportIOError.unableSyscall(
                    path: object.path, call: "fchmod", error: String(cString: strerror(errno)))
            }
        }

    }

    /// Can't use Basic's file utilities without data conversion.
    /// Instead we implement a low level write loop.
    private func writeFileData(
        fd: CInt, data: LLBFastData, startOffset: UInt64, debugPath: AbsolutePath
    ) throws {
        var dataOffset: Int = 0
        repeat {
            let (uint_off, overflow) = startOffset.addingReportingOverflow(UInt64(dataOffset))
            guard let file_offset = off_t(exactly: uint_off), !overflow else {
                throw LLBExportIOError.unableSyscall(
                    path: debugPath, call: "pwrite", error: String(cString: strerror(ERANGE)))
            }

            let err: CInt = data.withContiguousStorage { ptr in
                let ret = pwrite(
                    fd, ptr.baseAddress!.advanced(by: dataOffset), ptr.count - dataOffset,
                    file_offset)
                if ret == -1 {
                    return errno
                } else {
                    dataOffset += ret
                    return 0
                }
            }
            guard err == 0 || err == EINTR else {
                throw LLBExportIOError.unableSyscall(
                    path: debugPath, call: "pwrite", error: String(cString: strerror(err)))
            }
        } while dataOffset < data.count
    }
}
