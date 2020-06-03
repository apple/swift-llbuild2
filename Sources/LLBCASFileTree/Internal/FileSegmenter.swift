// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic
import NIOConcurrencyHelpers

import LLBSupport

/// FileSegmenter is to facilitate slicing the file into fixed chunks
/// in a way that optimizes for memory and file descriptors' usage
/// and removes data consistency race conditions.
///
/// The class is thread-safe.
internal final class FileSegmenter {
    /// Import path. FIXME: move logging itself out of this class.
    private let importPath: AbsolutePath

    /// Open path.
    let path: AbsolutePath

    /// Stat from the first time we opened the file.
    public let statInfo: stat

    /// A segment size to use
    private let segmentSize: Int

    /// The file descriptor to use. An optimization for small files.
    private let reuseFD: UnsafeEmbeddedAtomic<CInt>

    /// mmap() is not used because it did not show performance benefits.
    private let mappedAt: UnsafeMutableRawPointer?

    /// Allow reading files which change mid-flight.
    private let allowInconsistency: Bool

    /// The original reported size of the file.
    var size: Int {
        return Int(statInfo.st_size)
    }

    var relativePath: String {
        return path.prettyPath(cwd: importPath)
    }

    internal enum Error: Swift.Error {
    case resourceChanged(reason: String)
    }

    private enum ConsistencyStatus: CustomStringConvertible {
        case Same
        case Deleted
        case Replaced
        case Modified(reason: String)

        var description: String {
            switch self {
            case .Same:
                return "OK"
            case .Deleted:
                return "file has been deleted"
            case .Replaced:
                return "file has been replaced"
            case .Modified(let reason):
                return "file has been modified: \(reason)"
            }
        }
    }

    /// Whether the just opened file is likely the same file (+- contents)
    /// compared to the file opened initially. Works better on filesystems
    /// with microsecond or better timestamp resolution.
    private func checkConsistency(ofSameFileOpenedAs fd: CInt) -> ConsistencyStatus {
        var other = stat()

        guard fstat(fd, &other) != -1 else {
            return .Deleted
        }

        guard (statInfo.st_mode & S_IFMT) == (other.st_mode & S_IFMT) else {
            return .Replaced
        }

#if canImport(Darwin)
        let isSameMtime =
            statInfo.st_mtimespec.tv_nsec == other.st_mtimespec.tv_nsec
            && statInfo.st_mtimespec.tv_sec == other.st_mtimespec.tv_sec
#else
        let isSameMtime =
            statInfo.st_mtim.tv_nsec == other.st_mtim.tv_nsec
            && statInfo.st_mtim.tv_sec == other.st_mtim.tv_sec
#endif

        let isSame = (isSameMtime
            && statInfo.st_size == other.st_size
            && statInfo.st_dev == other.st_dev
            && statInfo.st_ino == other.st_ino)

        guard isSame else {
            return .Modified(reason: "oldStat: \(statInfo) != newStat: \(other)")
        }

        return .Same
    }

    /// When to mmap files:
    /// https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html#//apple_ref/doc/uid/TP40010765-CH2-SW1
    init(importPath: AbsolutePath, _ path: AbsolutePath, segmentSize: Int, minMmapSize: Int, allowInconsistency: Bool) throws {
        assert(segmentSize >= 1, "Too small segment size to split files")
        assert(minMmapSize >= 4096, "Too small minimum size for mmap(2)")
        let segmentSize = max(segmentSize, 1)
        let minMmapSize = max(minMmapSize, 1)

        var fd = try LLBFutureFileSystem.openImpl(path.pathString, flags: O_RDONLY | O_NOFOLLOW)
        defer { if fd >= 0 { close(fd) } }

        var sb = stat()
        guard fstat(fd, &sb) != -1 else {
            throw FileSystemError(errno: errno)
        }
        guard (sb.st_mode & S_IFMT) == S_IFREG else {
            throw FileSystemError.ioError
        }

        self.importPath = importPath
        self.path = path
        self.statInfo = sb
        self.segmentSize = segmentSize
        self.allowInconsistency = allowInconsistency

        let reportedSize = Int(sb.st_size)

        // For relatively small size, just read them in memory.
        guard reportedSize >= minMmapSize else {
            if reportedSize == 0 {
                // Do not stash fds for empty files.
                self.reuseFD = .init(value: -1)
            } else {
                self.reuseFD = .init(value: fd)
                fd = -1
            }
            self.mappedAt = nil
            return
        }

        // This is a large file, mmap it and retain the mapping until EOL.
        let mmapReturnValue = mmap(nil, reportedSize, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0)
        guard let basePointer = mmapReturnValue, basePointer != MAP_FAILED else {
            throw FileSystemError(errno: errno)
        }

        posix_madvise(basePointer, reportedSize, POSIX_MADV_SEQUENTIAL | POSIX_MADV_WILLNEED)

        self.reuseFD = .init(value: -1)
        self.mappedAt = basePointer
    }

    deinit {
        let fd = self.reuseFD.exchange(with: -1)
        if fd >= 0 {
            close(fd)
        }

        if let addr = mappedAt {
            munmap(addr, Int(statInfo.st_size))
        }

        reuseFD.destroy()
    }

    /// Fetch a given segment from the file, while checking that the file
    /// hasn't changed. It is still racy, but better than nothing.
    /// In case of legitimately no data left in the file the nil is returned.
    ///
    /// The `isEOF` is necessary to avoid opening small files twice.
    func fetchSegment(segmentNumber: Int) throws -> (LLBFastData, isEOF: Bool)? {

        let (fileOffset, overflow) = segmentSize.multipliedReportingOverflow(by: segmentNumber)
        guard !overflow else {
            throw FileSystemError(errno: ERANGE)
        }
        let fileSize = Int(statInfo.st_size)
        let currentSegmentSize = min(fileSize - fileOffset, segmentSize)
        if currentSegmentSize <= 0 {
            if fileOffset == 0, statInfo.st_size == 0 {
                // It is safe to not to check whether the file is still zero.
                // This way even if the file changes we're on the safe side
                // of the race, sending the idea that the file had changed
                // either completely before or completely after we've used it.
                return (LLBFastData([]), isEOF: true)
            } else {
                return nil
            }
        }
        let atEOF = fileOffset + currentSegmentSize >= fileSize

        if let basePointer = self.mappedAt {
            let ptr = UnsafeRawBufferPointer(start: basePointer.advanced(by: fileOffset), count: currentSegmentSize)
            return (LLBFastData(ptr, deallocator: { _ in
                    withExtendedLifetime(self) { }
                }), isEOF: atEOF)
        }

        let fd: CInt
        switch reuseFD.exchange(with: -1) {
        case let reused where reused >= 0:
            fd = reused
        default:
            let newFD: CInt
            do {
                newFD = try LLBFutureFileSystem.openImpl(path.pathString, flags: O_RDONLY | O_NOFOLLOW)
            } catch {
                guard allowInconsistency else {
                    // Ignore the details of the actual error: in most cases
                    // (file not found, or something else) it is as good as
                    // "something is different with this file".
                    // After all, we have succeeded opening it before.
                    throw Error.resourceChanged(reason: "Can't reopen: \(error)")
                }

                // If we can't open something that we used to be able to open,
                // just consider it deleted/truncated and upload empty
                // (if less than a segment size) or truncated.
                return (LLBFastData([]), isEOF: true)
            }

            // The main check to perform here is whether it is a regular file
            // (S_IFREG). The rest is just an early bail out: we do check the
            // stat information again after the file chunk is read.
            let inconsistency = self.checkConsistency(ofSameFileOpenedAs: newFD)
            switch inconsistency {
            case .Same,
                 .Modified where allowInconsistency == true:
                // Do not log here, avoid duplicate logging.
                break
            case .Deleted, .Replaced:
                close(newFD)
                throw FileSystemError.noEntry
            case .Modified:
                close(newFD)
                throw Error.resourceChanged(reason: String(describing: inconsistency))
            }

            fd = newFD
        }
        defer { close(fd) }

        let data = try LLBFutureFileSystem.syncReadComplete(fd: fd, readSize: currentSegmentSize, fileOffset: fileOffset)

        if atEOF, segmentNumber == 0 {
            // If we've just slurped the whole relatively short (1 segm) file,
            // we don't have to check whether the file has been modified or
            // not at the end of the read:
            //  - If it is a first read, we'll have a chance to check
            //    this on a subsequent read. And upload something else instead
            //    if it changed.
            //  - If it is the last read (where we use data for the actual
            //    upload), then this situation is just freezes the inconsistent
            //    state of the [relatively small] file.

            // Actually, ignore all that, let's get safety over speed.
            // Also, testing didn't find material changes.
        }

        // Even if we read the file correctly, make sure it didn't change
        // after we've read it. That would be a race.
        let inconsistency: ConsistencyStatus
        if data.count != currentSegmentSize {
            inconsistency = .Modified(reason: "File size shrunk")
        } else {
            inconsistency = self.checkConsistency(ofSameFileOpenedAs: fd)
        }
        switch inconsistency {
        case .Same:
            break
        case .Modified where allowInconsistency == true:
            // Note inconsistency
            break
        case .Deleted, .Replaced:
            // The file was deleted at _some_ point in the middle of processing.
            throw FileSystemError.noEntry
        case .Modified(let reason):
            throw Error.resourceChanged(reason: reason)
        }

        return (LLBFastData(data), isEOF: atEOF)
    }
}

