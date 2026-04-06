// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Foundation
import NIOCore
import TSCBasic

/// Asynchronous file system interface integrated with `Future`s.
package struct FXFutureFileSystem {

    package let batchingQueue: LLBBatchingFutureOperationQueue

    /// - Parameters:
    ///    - group:     Threads capable of running futures.
    ///    - maxConcurrentOperationCount:
    ///                 Operations to execute in parallel.
    package init(group: FXFuturesDispatchGroup) {
        let solidStateDriveParallelism = 8
        self.batchingQueue = LLBBatchingFutureOperationQueue(
            name: "llbuild2.futureFileSystem", group: group,
            maxConcurrentOperationCount: solidStateDriveParallelism)
    }

    package func readFileContents(_ path: AbsolutePath) -> FXFuture<ArraySlice<UInt8>> {
        let pathString = path.pathString
        return batchingQueue.execute {
            try ArraySlice(Self.syncRead(pathString))
        }
    }

    package func readFileContentsWithStat(_ path: AbsolutePath) -> FXFuture<
        (contents: ArraySlice<UInt8>, stat: stat)
    > {
        let pathString = path.pathString
        return batchingQueue.execute {
            try Self.syncReadWithStat(pathString)
        }
    }

    package func getFileInfo(_ path: AbsolutePath) -> FXFuture<stat> {
        let pathString = path.pathString
        return batchingQueue.execute {
            var sb = stat()
            guard stat(pathString, &sb) != -1 else {
                throw FileSystemError(errno: errno, path)
            }
            return sb
        }
    }

    /// Read in the given file.
    package static func syncRead(_ path: String) throws -> [UInt8] {
        let fd = try Self.openImpl(path)
        defer { close(fd) }

        let expectedFileSize = 8192  // Greater than 78% of stdlib headers.
        let firstBuffer = try syncReadComplete(fd: fd, readSize: expectedFileSize)
        guard firstBuffer.count == expectedFileSize else {
            // A small file was read without hitting stat(). Good.
            return firstBuffer
        }

        // Fast path failed. Measure file size and try to swallow it whole.
        var sb = stat()
        guard fstat(fd, &sb) == 0 else {
            throw FileSystemError(.ioError(code: 0), try? AbsolutePath(validating: path))
        }

        if expectedFileSize > sb.st_size {
            // File size is less than what was already read in.
            throw FileSystemError(.ioError(code: 0), try? AbsolutePath(validating: path))
        } else if expectedFileSize == sb.st_size {
            // Avoid copying if the file is exactly 8kiB.
            return firstBuffer
        }

        return try [UInt8](unsafeUninitializedCapacity: Int(sb.st_size)) { ptr, initializedCount in
            var consumedSize = expectedFileSize
            defer { initializedCount = consumedSize }

            // Copy the already read bytes.
            firstBuffer.withUnsafeBytes { firstBufferBytes in
                let alreadyRead = UnsafeRawBufferPointer(
                    start: firstBufferBytes.baseAddress!, count: expectedFileSize)
                UnsafeMutableRawBufferPointer(ptr).copyMemory(from: alreadyRead)
            }

            consumedSize += try unsafeReadCompleteImpl(
                fd: fd, ptr, bufferOffset: consumedSize, fileOffset: 0)
        }
    }

    /// Return the bytes and sometimes the stat information for the file.
    /// The stat information is a byproduct and can be used as an optimization.
    private static func syncReadWithStat(_ path: String) throws -> (
        contents: ArraySlice<UInt8>, stat: stat
    ) {
        let fd = try Self.openImpl(path)
        defer { close(fd) }

        // Fast path failed. Measure file size and try to swallow it whole.
        var sb = stat()
        guard fstat(fd, &sb) == 0 else {
            throw FileSystemError(.ioError(code: errno), try? AbsolutePath(validating: path))
        }

        let data = try syncReadComplete(fd: fd, readSize: Int(sb.st_size))
        guard data.count == sb.st_size else {
            // File size is less than advertised.
            throw FileSystemError(.ioError(code: 0), try? AbsolutePath(validating: path))
        }

        return (contents: ArraySlice(data), stat: sb)
    }

    /// Read until reaches the readSize or an EOF.
    /// The difference between hitting the buffer with or without EOF can not
    /// be inferred from the return value of this function.
    package static func syncReadComplete(fd: CInt, readSize: Int, fileOffset: Int = 0) throws
        -> [UInt8]
    {

        return try [UInt8](unsafeUninitializedCapacity: readSize) { ptr, initializedCount in
            initializedCount = try unsafeReadCompleteImpl(
                fd: fd, ptr, bufferOffset: 0, fileOffset: fileOffset)
        }
    }

    package static func openImpl(_ path: String, flags: CInt = O_RDONLY) throws -> CInt {
        let fd = open(path, flags | O_CLOEXEC)
        guard fd != -1 else {
            // FIXME: Need to fix FileSystemError to not require an AbsolutePath.
            throw FileSystemError(errno: errno, (try? AbsolutePath(validating: path)) ?? .root)
        }
        return fd
    }

    /// Read until the end of the given buffer or EOF.
    /// Returns the bytes read.
    private static func unsafeReadCompleteImpl(
        fd: CInt, _ ptr: UnsafeMutableBufferPointer<UInt8>, bufferOffset: Int, fileOffset: Int
    ) throws -> Int {
        var offset = 0
        while bufferOffset + offset < ptr.count {
            let (off, overflow) = fileOffset.addingReportingOverflow(offset)
            guard !overflow else {
                // FIXME: Need to fix FileSystemError to allow ERANGE.
                throw FileSystemError(.unknownOSError)
            }

            let count = try unsafeReadImpl(
                fd: fd, ptr, bufferOffset: bufferOffset + offset, fileOffset: off)
            if count > 0 {
                offset += count
            } else if count == 0 {
                break
            } else {
                fatalError("read() returned \(count)")
            }
        }

        return offset
    }

    private static func unsafeReadImpl(
        fd: CInt, _ ptr: UnsafeMutableBufferPointer<UInt8>, bufferOffset: Int, fileOffset: Int
    ) throws -> Int {
        assert(bufferOffset < ptr.count)

        while true {
            guard let off = off_t(exactly: fileOffset) else {
                // FIXME: Need to fix FileSystemError to allow ERANGE.
                throw FileSystemError(.unknownOSError)
            }

            let ret = pread(fd, ptr.baseAddress! + bufferOffset, ptr.count - bufferOffset, off)
            switch ret {
            case let count where count > 0:
                return count
            case 0:
                return 0
            case -1:
                guard errno == EINTR else {
                    throw FileSystemError.init(.ioError(code: errno))
                }
                continue
            default:
                fatalError("pread() returned \(ret)")
            }
        }
    }

}
