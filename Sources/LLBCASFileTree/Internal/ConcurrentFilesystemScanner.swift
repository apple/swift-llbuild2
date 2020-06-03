// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic
import NIO
import NIOConcurrencyHelpers

import LLBSupport


/// A thread-safe concurrent scan of the filesystem.
/// Beware of the file descriptor requirements: each open directory
/// keeps open a file descriptor. The number of file descriptors required
/// is the maximum depth of the directory multiplied by the maximum
/// number of concurent accessors.
class ConcurrentFilesystemScanner: Sequence {
    public typealias Iterator = FilesystemIterator
    public typealias Element = (path: AbsolutePath, type: FilesystemObjectType)

    /// A lock of all variables in this class.
    fileprivate let sharedLock = ConditionLock<Int>(value: 0)

    /// Items that have just been discovered but not yet reported to the
    /// user or expanded further (if directories).
    fileprivate var unprocessed = CircularBuffer<FilesystemPathInfo>()

    /// Directories that have probably been reported to the users (or at least
    /// scheduled to be reported by the individual concurrent iterators,
    /// but remain the source of data for others threads.
    fileprivate var expanding = CircularBuffer<FilesystemDirectoryIterator>()

    /// A promise that some thread is working on a piece of data it stashed
    /// and may add more work in a jiffy. This allows competing threads to
    /// linger around even if there are no data immediately available
    /// in `unprocessed` or `expanding` buffers.
    fileprivate var hasUnfinishedWork = 0

    /// The `pathFilter` function is applied to each input object to detect
    /// whether to include it in the iterator output.
    fileprivate let pathFilter: ((AbsolutePath, FilesystemObjectType) -> Bool)?

    /// Returns a scanner which can be used to concurrently read the items
    /// off the filesystem three.
    /// The `pathFilter` argument can be used to avoid including
    /// files and directories in the iterator output.
    init(_ path: AbsolutePath, pathFilter: ((AbsolutePath, FilesystemObjectType) -> Bool)? = nil) throws {
        self.pathFilter = pathFilter
        let node = try FilesystemPathInfo(path)
        unprocessed.append(node)
    }

    /// Return a thread-safe iterator that returns an item by item.
    /// More than one iterator can be initialized at the same time.
    /// The iterators may be run concurrently, even though each individual
    /// iterator can not be accessed concurrently by multiple threads.
    public func makeIterator() -> FilesystemIterator {
        return FilesystemIterator(scanner: self)
    }
}

/// A single `FilesystemIterator` produces a stream of filesystem objectes.
/// While the single iterator is not thread-safe, multiple iterators
/// can be instantiated in different threads off the same scanner to scan
/// the file system concurrently.
class FilesystemIterator: IteratorProtocol {
    public typealias Element = (path: AbsolutePath, type: FilesystemObjectType)

    /// Iterators concurrently and safely access a single shared scanner.
    private let scanner: ConcurrentFilesystemScanner

    /// Files that are about to be reported to the user via `next()`.
    /// Despite the fact that we report the just the names and types,
    /// we keep the full `FilesystemPathInfo` objects stashed around,
    /// to be able to put them back to the shared queue in case the iterator
    /// is not read in full. This allows other threads to pick up the slack
    /// if one thread decides not to finish the scan early.
    private var stashed = NIO.CircularBuffer<FilesystemPathInfo>()

    fileprivate init(scanner: ConcurrentFilesystemScanner) {
        self.scanner = scanner
    }

    deinit {
        // Return unprocessed work back to the shared queue.
        guard stashed.isEmpty == false else {
            return
        }

        scanner.sharedLock.lock()
        for pathInfo in stashed {
            scanner.unprocessed.append(pathInfo)
        }
        // Returned some work; unlock those who wait for it.
        scanner.sharedLock.unlock(withValue: 0)
    }

    /// Filter the filesystem object.
    private func filter(_ info: FilesystemPathInfo) -> Bool {
        if let filterOK = scanner.pathFilter {
            guard filterOK(info.path, info.type) else {
                // Ignore.
                return false
            }
        }
        return true
    }

    private enum Step {
    /// The scanner gave us an open directory so we can read more files from it.
    case iterateDirectory(FilesystemDirectoryIterator)
    /// The scanner gave us a bunch of files (and maybe a directory), so
    /// we can stash them and maybe expand that directory into files while
    /// we are at it.
    case expand([FilesystemPathInfo])
    // Some background process might populate.
    case waitForMoreWork
    case finished
    }

    public func next() -> Element? {

        out: repeat {
            let step: Step

            if let pathInfo = stashed.popFirst() {
                return (path: pathInfo.path, type: pathInfo.type)
            }

            scanner.sharedLock.lock()
            if let current = scanner.expanding.popFirst() {
                scanner.hasUnfinishedWork += 1
                step = .iterateDirectory(current)
                scanner.sharedLock.unlock(withValue: 1)
            } else if let unprocessedPath = scanner.unprocessed.popFirst() {
                // Get a number of files off the queue until we hit
                // a limit or a directory. We can only expand one directory.
                if case .directory = unprocessedPath.info {
                    // Stop and go expand this dir outside the lock.
                    step = .expand([unprocessedPath])
                } else {
                    var array = [unprocessedPath]
                    while let pathInfo = scanner.unprocessed.popFirst() {
                        array.append(pathInfo)
                        if case .directory = pathInfo.info {
                            // Stop and go expand it outside the lock.
                            break
                        }
                        if array.count > 1000 { break }
                    }
                    step = .expand(array)
                }
                scanner.hasUnfinishedWork += 1
                scanner.sharedLock.unlock(withValue: 1)
            } else if scanner.hasUnfinishedWork > 0 {
                step = .waitForMoreWork
                scanner.sharedLock.unlock(withValue: 1)
            } else {
                step = .finished
                scanner.sharedLock.unlock(withValue: 0)
            }

            // Directory scans are done on the individual threads outside
            // of the scanner locks, for concurrency.
            // Returns `true` if there are more directory entries
            // and we need to put the directory iterator back into
            // the shared queue.
            func grabFilenames(from dir: FilesystemDirectoryIterator) -> Bool {
                guard let (entries, hasMoreEntries) = dir.next() else {
                    return false
                }

                var moreDirectories = [FilesystemPathInfo]()
                for entry in entries {
                    guard let pathInfo = try? FilesystemPathInfo(dir.path.appending(component: entry.name), hint: entry.type) else {
                        continue
                    }
                    guard filter(pathInfo) else {
                        continue
                    }
                    switch pathInfo.info {
                    case .directory:
                        moreDirectories.append(pathInfo)
                    case .file, .symlink, .nonRegular:
                        stashed.append(pathInfo)
                    }
                }

                scanner.sharedLock.lock()
                for dirInfo in moreDirectories {
                    scanner.unprocessed.append(dirInfo)
                }
                scanner.sharedLock.unlock(withValue: 0)
                return hasMoreEntries
            }

            switch step {
            case let .iterateDirectory(dir):
                let hasMoreEntries = grabFilenames(from: dir)
                scanner.sharedLock.lock()
                if hasMoreEntries {
                    // Put back the dir, let others deal with it.
                    scanner.expanding.prepend(dir)
                }
                scanner.hasUnfinishedWork -= 1
                scanner.sharedLock.unlock(withValue: 0)
            case let .expand(pathInfos):
                var putBackExpandingDirs = [FilesystemDirectoryIterator]()
                for pathInfo in pathInfos {
                    switch pathInfo.info {
                    case .file, .symlink, .nonRegular:
                        stashed.append(pathInfo)
                    case let .directory(dir):
                        if grabFilenames(from: dir) {
                            putBackExpandingDirs.append(dir)
                        }
                        // Report the directory itself to the requester.
                        stashed.append(pathInfo)
                    }
                }
                scanner.sharedLock.lock()
                scanner.hasUnfinishedWork -= 1
                for dir in putBackExpandingDirs {
                    scanner.expanding.prepend(dir)
                }
                scanner.sharedLock.unlock(withValue: 0)
            case .waitForMoreWork:
                scanner.sharedLock.lock(whenValue: 0)
                // Waiting util items are populated.
                scanner.sharedLock.unlock()
            case .finished:
                break out
            }

        } while true

        return nil
    }
}

/// A non-recursive representation of a filesystem inode by the given path.
struct FilesystemPathInfo {
    public let path: AbsolutePath
    public let info: PathInfo

    public enum PathInfo {
    /// A plain file.
    case file
    /// A symbolic link.
    case symlink
    /// A source of directory information.
    case directory(entries: FilesystemDirectoryIterator)
    /// Neither file nor a directory.
    case nonRegular(type: FilesystemObjectType)
    }

    /// Return the filesystem object type at the moment of discovery.
    public var type: FilesystemObjectType {
        switch info {
        case .file:
            return .REG
        case .symlink:
            return .LNK
        case .directory:
            return .DIR
        case .nonRegular(let type):
            return type
        }
    }

    fileprivate init(_ path: AbsolutePath, hint: FilesystemObjectType = .UNKNOWN) throws {
        switch hint {
        case .UNKNOWN:
            // This can be a network FS.
            var statInfo = stat()
            guard lstat(path.pathString, &statInfo) != -1 else {
                throw FileSystemError(errno: errno)
            }
            let ftype = FilesystemObjectType(st_mode: statInfo.st_mode)
            guard case .UNKNOWN = ftype else {
                self = try Self(path, hint: ftype)
                return
            }
            // Avoid runaway recursion.
            self.info = .nonRegular(type: .UNKNOWN)
        case .REG:
            self.info = .file
        case .LNK:
            self.info = .symlink
        case .DIR:
            self = try Self(directory: path)
            return
        default:
            self.info = .nonRegular(type: hint)
        }
        self.path = path
    }

    public init(directory path: AbsolutePath) throws {
        let entries = try FilesystemDirectoryIterator(path)
        self.path = path
        self.info = .directory(entries: entries)
    }
}

/// A thread-safe iterator through the directory contents.
/// May hold an open file descriptor to huge directories.
class FilesystemDirectoryIterator: IteratorProtocol {
    // An iterator element is a list of files and a flag
    // hasMoreEntries indicating whether this is a complete list.
    // This allows us to minimize the use of mutexes.
    public typealias Element = ([NameAndType], hasMoreEntries: Bool)

    fileprivate let path: AbsolutePath
    private let dirLock = NIOConcurrencyHelpers.Lock()
#if canImport(Darwin)
    private var dir: UnsafeMutablePointer<DIR>!
#elseif os(Linux)
    private var dir: OpaquePointer!
#else
#error("Unsupported platform")
#endif
    public typealias NameAndType = (name: String, type: FilesystemObjectType)
    private var prefetched = [NameAndType]()

    deinit {
        if let dir = dir {
            closedir(dir)
        }
    }

    public init(_ path: AbsolutePath) throws {
        guard let dir = opendir(path.pathString) else {
            // The fd is owned by the caller if we throw.
            throw FileSystemError(errno: errno)
        }
        self.path = path
        self.dir = dir

        // Prefetch entries. For small directories that'll release the fd.
        _ = prefetchNames()
    }

    /// Get the next node from the filesystem.
    public func next() -> Element? {
        return dirLock.withLock {
            guard let entries = getNextEntries() else {
                return nil
            }
            return (entries, hasMoreEntries: dir != nil)
        }
    }

    /// CONCURRENCY: Must be called under a `dirLock`.
    private func getNextEntries() -> [NameAndType]? {

        if prefetched.isEmpty {
            // Prefetch a bunch more names.
            guard prefetchNames() else {
                return nil
            }
        }

        guard prefetched.isEmpty else {
            let p = prefetched
            prefetched = []
            return p
        }

        return nil
    }

    /// CONCURRENCY: Must be called under a `dirLock`.
    private func prefetchNames() -> Bool {

        // Hit the end of the directory at some point.
        guard let dir = dir else {
            return false
        }

        var countPrefetched = 0
        repeat {
            guard let entry = readdir(dir) else {
                precondition(closedir(dir) == 0, "closedir() failed")
                self.dir = nil
                break
            }

            // Remove "." and ".." that can appear _anywhere_ in the list.
            let dot = Int8(bitPattern: UInt8(ascii: "."))
            switch (entry.pointee.d_name.0, entry.pointee.d_name.1, entry.pointee.d_name.2) {
            case (dot, 0, _), (dot, dot, 0):
                continue
            default:
                break
            }

            guard let filename = entry.pointee.name else {
                // Not an UTF-8-convertible name. Ignore it with prejudice.
                continue
            }

            let ftype = FilesystemObjectType(d_type: entry.pointee.d_type)
            prefetched.append((name: filename, type: ftype))
            countPrefetched += 1
        } while countPrefetched < 1000

        return prefetched.count > 0
    }

}


/// Directory entry type, `man 5 dirent`.
/// We don't assign values there because the DT_xxx and S_IFxxx values
/// are different yet we support them all since they still form the same set.
public enum FilesystemObjectType: UInt8 {
    case UNKNOWN
    case FIFO
    case CHR
    case DIR
    case BLK
    case REG
    case LNK
    case SOCK
    case WHT

    /// Override the rawValue initializer. Not clear which "value" is implied.
    public init?(rawValue: UInt8) {
        return nil
    }

    /// Initialize from dirent's d_type.
    public init(d_type: UInt8) {
#if canImport(Darwin)
        switch CInt(d_type) {
        case DT_UNKNOWN: self = .UNKNOWN
        case DT_FIFO: self = .FIFO
        case DT_CHR: self = .CHR
        case DT_DIR: self = .DIR
        case DT_BLK: self = .BLK
        case DT_REG: self = .REG
        case DT_LNK: self = .LNK
        case DT_SOCK: self = .SOCK
        case DT_WHT: self = .WHT
        default: self = .UNKNOWN
        }
#else
        switch Int(d_type) {
        case DT_UNKNOWN: self = .UNKNOWN
        case DT_FIFO: self = .FIFO
        case DT_CHR: self = .CHR
        case DT_DIR: self = .DIR
        case DT_BLK: self = .BLK
        case DT_REG: self = .REG
        case DT_LNK: self = .LNK
        case DT_SOCK: self = .SOCK
        case DT_WHT: self = .WHT
        default: self = .UNKNOWN
        }
#endif
    }

    /// Initialize from stat's st_mode.
    public init(st_mode: mode_t) {
        switch (st_mode & S_IFMT) {
        case S_IFIFO: self = .FIFO
        case S_IFCHR: self = .CHR
        case S_IFDIR: self = .DIR
        case S_IFBLK: self = .BLK
        case S_IFREG: self = .REG
        case S_IFLNK: self = .LNK
        case S_IFSOCK: self = .SOCK
#if os(macOS)
        case S_IFWHT: self = .WHT
#endif
        default: self = .UNKNOWN
        }
    }
}
