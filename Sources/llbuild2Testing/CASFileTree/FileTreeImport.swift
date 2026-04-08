// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import Atomics
import FXCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import TSCBasic
import TSCLibc
import TSCUtility

package protocol FXCASFileTreeImportProgressStats: AnyObject {
    var toImportFiles: Int { get }
    var toImportObjects: Int { get }
    var toImportBytes: Int { get }
    var checksProgressObjects: Int { get }
    var checksProgressBytes: Int { get }
    var checkedObjects: Int { get }
    var checkedBytes: Int { get }
    var uploadsProgressObjects: Int { get }
    var uploadsProgressBytes: Int { get }
    var uploadedObjects: Int { get }
    var uploadedBytes: Int { get }
    var uploadedMetadataBytes: Int { get }
    var importedObjects: Int { get }
    var importedBytes: Int { get }

    var phase: FXCASFileTree.ImportPhase { get }

    var debugDescription: String { get }
}

extension FXCASFileTree {

    /// Serialization format.
    package enum WireFormat: String, CaseIterable, Sendable {
        /// Binary encoding for directory and file data
        case binary
        /// Binary encoding with data compression applied.
        case compressed
    }

    package enum ImportError: Swift.Error {
        case unreadableDirectory(AbsolutePath)
        case unreadableLink(AbsolutePath)
        case unreadableFile(AbsolutePath)
        case modifiedFile(AbsolutePath, reason: String)
        case compressionFailed(String)
    }

    package enum ImportPhase: Int, Comparable, Sendable {
        case AssemblingPaths
        case EstimatingSize
        case CheckIfUploaded
        case UploadingFiles
        case UploadingWait
        case UploadingDirs
        case ImportFailed
        case ImportSucceeded

        /// Whether no futher phase change is going to happen.
        package var isFinalPhase: Bool {
            return self == .ImportSucceeded || self == .ImportFailed
        }

        package static func < (lhs: ImportPhase, rhs: ImportPhase) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    package struct PreservePosixDetails: Sendable {
        /// Preserve POSIX file permissions.
        package var preservePosixMode = false

        /// Preserve POSIX user and group information.
        package var preservePosixOwnership = false

        fileprivate var preservationEnabled: Bool {
            preservePosixMode || preservePosixOwnership
        }

        package init() {}
    }

    /// Modifiers for the default behavior of the `import` call.
    package struct ImportOptions: Sendable {
        /// The serialization format for persisting the CASTrees.
        package var wireFormat: WireFormat

        /// File chunk sizing:
        /// Empirically, a good balance between
        ///  - network transfer speed (the larger the segment the faster)
        ///  - the size of the [FXDataID] (the larger the segment the better)
        ///  - local resource utilization (the smaller the better)
        ///  - future "random" access time to first byte latency (smaller best)
        package var fileChunkSize: Int

        /// Minimum file size to employ mmap(2).
        package var minMmapSize = Int.max

        /// Allocator for compression. If not set, a ByteBufferAllocator
        /// is going to be used if compression is requested.
        package var compressBufferAllocator: FXByteBufferAllocator? = nil

        /// Skip unreadable files or directories.
        package var skipUnreadable = false

        /// Allow importing of data which changes mid-flight.
        /// Necessary if absolutely have to import something that has
        /// a couple of files changing all the time (logs?).
        package var relaxConsistencyChecks = false

        /// Preserve file permissions and ownership.
        package var preservePosixDetails = PreservePosixDetails()

        /// A function to check whether path name matches the
        /// expectations before importing. If the directory name does not
        /// match expectation, it is not recursed into.
        /// NB: The filter argument is an absolute path _relative to the
        /// import location_. A top level imported directory becomes "/".
        package var pathFilter: (@Sendable (String) -> Bool)?

        /// Shared queues for operations that should be limited by mainly the
        /// data drive parallelism, network concurrency parallelism,
        /// and CPU parallelism.
        package var sharedQueueSSD: LLBBatchingFutureOperationQueue? = nil
        package var sharedQueueNetwork: FXFutureOperationQueue? = nil
        package var sharedQueueCPU: LLBBatchingFutureOperationQueue? = nil

        /// Create a set of import options.
        package init(
            fileChunkSize: Int = 8 * 1024 * 1024,
            wireFormat: WireFormat = .binary
        ) {
            self.fileChunkSize = fileChunkSize
            self.wireFormat = wireFormat
        }

        /// Create a copy of the options with a particular `wireFormat`.
        package func with(wireFormat: WireFormat) -> Self {
            var opts = self
            opts.wireFormat = wireFormat
            return opts
        }
    }

    package final class ImportProgressStats: FXCASFileTreeImportProgressStats,
        CustomDebugStringConvertible, Sendable
    {

        /// Number of plain files to import (not directories).
        let toImportFiles_ = ManagedAtomic<Int>(0)
        /// Number of objects to import.
        let toImportObjects_ = ManagedAtomic<Int>(0)
        /// Number of bytes to import.
        let toImportBytes_ = ManagedAtomic<Int>(0)

        /// Number of objects currently being presence-checked in CAS.
        let checksProgressObjects_ = ManagedAtomic<Int>(0)
        /// Number of bytes currently being presence-checked in CAS.
        let checksProgressBytes_ = ManagedAtomic<Int>(0)
        /// Number of objects checked in CAS.
        let checkedObjects_ = ManagedAtomic<Int>(0)
        /// Number of bytes checked in CAS.
        let checkedBytes_ = ManagedAtomic<Int>(0)

        /// Uploads currently in progress, objects.
        let uploadsProgressObjects_ = ManagedAtomic<Int>(0)
        /// Uploads currently in progress, bytes.
        let uploadsProgressBytes_ = ManagedAtomic<Int>(0)
        /// Objects moved over the wire.
        let uploadedObjects_ = ManagedAtomic<Int>(0)
        /// Bytes moved over the wire.
        let uploadedBytes_ = ManagedAtomic<Int>(0)
        /// Uploaded directory descriptions (not yet part of aggregateSize!)
        let uploadedMetadataBytes_ = ManagedAtomic<Int>(0)

        /// Objects ended up ended up being stored in the CAS.
        let importedObjects_ = ManagedAtomic<Int>(0)
        /// Bytes ended up being stored in the CAS.
        let importedBytes_ = ManagedAtomic<Int>(0)

        /// Execution phase
        internal let phase_ = ManagedAtomic<Int>(0)

        package var toImportFiles: Int { toImportFiles_.load(ordering: .relaxed) }
        package var toImportObjects: Int { toImportObjects_.load(ordering: .relaxed) }
        package var toImportBytes: Int { toImportBytes_.load(ordering: .relaxed) }
        package var checksProgressObjects: Int { checksProgressObjects_.load(ordering: .relaxed) }
        package var checksProgressBytes: Int { checksProgressBytes_.load(ordering: .relaxed) }
        package var checkedObjects: Int { checkedObjects_.load(ordering: .relaxed) }
        package var checkedBytes: Int { checkedBytes_.load(ordering: .relaxed) }
        package var uploadsProgressObjects: Int { uploadsProgressObjects_.load(ordering: .relaxed) }
        package var uploadsProgressBytes: Int { uploadsProgressBytes_.load(ordering: .relaxed) }
        package var uploadedObjects: Int { uploadedObjects_.load(ordering: .relaxed) }
        package var uploadedBytes: Int { uploadedBytes_.load(ordering: .relaxed) }
        package var uploadedMetadataBytes: Int { uploadedMetadataBytes_.load(ordering: .relaxed) }
        package var importedObjects: Int { importedObjects_.load(ordering: .relaxed) }
        package var importedBytes: Int { importedBytes_.load(ordering: .relaxed) }

        fileprivate func reset() {
            phase_.store(0, ordering: .relaxed)
            toImportFiles_.store(0, ordering: .relaxed)
            toImportObjects_.store(0, ordering: .relaxed)
            toImportBytes_.store(0, ordering: .relaxed)
            checksProgressObjects_.store(0, ordering: .relaxed)
            checksProgressBytes_.store(0, ordering: .relaxed)
            checkedObjects_.store(0, ordering: .relaxed)
            checkedBytes_.store(0, ordering: .relaxed)
            uploadsProgressObjects_.store(0, ordering: .relaxed)
            uploadsProgressBytes_.store(0, ordering: .relaxed)
            uploadedObjects_.store(0, ordering: .relaxed)
            uploadedBytes_.store(0, ordering: .relaxed)
            uploadedMetadataBytes_.store(0, ordering: .relaxed)
            importedObjects_.store(0, ordering: .relaxed)
            importedBytes_.store(0, ordering: .relaxed)
        }

        package internal(set) var phase: ImportPhase {
            get { ImportPhase(rawValue: phase_.load(ordering: .relaxed))! }
            set {
                repeat {
                    let currentPhase = phase
                    guard !currentPhase.isFinalPhase else {
                        break  // Do not change the final state.
                    }
                    guard
                        !phase_.compareExchange(
                            expected: currentPhase.rawValue, desired: newValue.rawValue,
                            ordering: .sequentiallyConsistent
                        ).0
                    else {
                        break  // State change succeeded.
                    }
                    // Repeat attempt if need to set the final state.
                } while newValue.isFinalPhase
                // It is OK not to be able to write not a final state;
                // the last state update wins anyway.
            }
        }

        package var debugDescription: String {
            return """
                {phase: \(phase), \
                toImportFiles: \(toImportFiles), \
                toImportObjects: \(toImportObjects), \
                toImportBytes: \(toImportBytes), \
                checksProgressObjects: \(checksProgressObjects), \
                checksProgressBytes: \(checksProgressBytes), \
                checkedObjects: \(checkedObjects), \
                checkedBytes: \(checkedBytes), \
                uploadsProgressObjects: \(uploadsProgressObjects), \
                uploadsProgressBytes: \(uploadsProgressBytes), \
                uploadedObjects: \(uploadedObjects), \
                uploadedBytes: \(uploadedBytes), \
                uploadedMetadataBytes: \(uploadedMetadataBytes), \
                importedObjects: \(importedObjects), \
                importedBytes: \(importedBytes)}
                """
        }

        package init() {}
    }

    /// Import an entire file system subtree into a database.
    ///
    /// - Parameters:
    ///   - path: The path to import.
    ///   - db: The database to import the content into.
    ///   - options: Import options.
    ///   - stats: Atomic stats counters.
    //
    // - FIXME: Move this to use TSC's FileSystem. For that, we need to add a
    //          way to get the contents of a symbolic link.
    package static func `import`(
        path importPath: AbsolutePath,
        to db: any FXCASDatabase,
        options optionsTemplate: FXCASFileTree.ImportOptions? = nil,
        stats providedStats: FXCASFileTree.ImportProgressStats? = nil,
        _ ctx: Context
    ) -> FXFuture<FXDataID> {
        let stats = providedStats ?? .init()

        // Adjust options
        var mutableOptions = optionsTemplate ?? ctx.fileTreeImportOptions ?? .init()
        switch mutableOptions.wireFormat {
        case .compressed where mutableOptions.compressBufferAllocator == nil:
            mutableOptions.compressBufferAllocator = FXByteBufferAllocator()
        default:
            break
        }
        let options = mutableOptions

        // Maximum number of outstanding db.contains and db.put operations.
        let initialNetConcurrency = 9_999
        return FXCASFileTree.recursivelyDecreasingLimit(
            on: db.group.next(), limit: initialNetConcurrency
        ) { limit in
            stats.reset()
            return CASTreeImport(
                importPath: importPath, to: db,
                options: options, stats: stats,
                netConcurrency: limit
            ).run(ctx)
        }
    }

    // Retry with lesser concurrency if we see unexpected network errors.
    private static func recursivelyDecreasingLimit<T>(
        on loop: FXFuturesDispatchLoop, limit: Int, _ body: @escaping (Int) -> FXFuture<T>
    ) -> FXFuture<T> {
        return body(limit).flatMapError { error -> FXFuture<T> in
            // Check if something retryable happened.
            guard case FXCASDatabaseError.retryableNetworkError(_) = error else {
                return loop.makeFailedFuture(error)
            }

            guard limit > 10 else {
                return loop.makeFailedFuture(error)
            }

            let newLimit = limit / 5

            let promise = loop.makePromise(of: T.self)
            _ = loop.scheduleTask(in: .seconds(3)) {
                recursivelyDecreasingLimit(on: loop, limit: newLimit, body)
                    .cascade(to: promise)
            }

            return promise.futureResult
        }
    }

}

private final class CASTreeImport: Sendable {

    let importPath: AbsolutePath
    let options: FXCASFileTree.ImportOptions
    let stats: FXCASFileTree.ImportProgressStats
    let ssdQueue: LLBBatchingFutureOperationQueue
    let netQueue: FXFutureOperationQueue
    let cpuQueue: LLBBatchingFutureOperationQueue

    let loop: FXFuturesDispatchLoop
    let _db: FXCASDatabase
    let finalResultPromise: LLBCancellablePromise<FXDataID>

    func dbContains(_ segm: SegmentDescriptor, _ ctx: Context) -> FXFuture<Bool> {
        stats.checksProgressObjects_.wrappingIncrement(ordering: .relaxed)
        stats.checksProgressBytes_.wrappingIncrement(by: segm.uncompressedSize, ordering: .relaxed)
        return segm.id.flatMap { id in
            return self._db.contains(id, ctx).map { result in
                guard self.finalResultPromise.isCompleted == false else {
                    return false
                }
                let stats = self.stats
                stats.checkedObjects_.wrappingIncrement(ordering: .relaxed)
                stats.checkedBytes_.wrappingIncrement(by: segm.uncompressedSize, ordering: .relaxed)
                stats.checksProgressObjects_.wrappingDecrement(ordering: .relaxed)
                stats.checksProgressBytes_.wrappingDecrement(
                    by: segm.uncompressedSize, ordering: .relaxed)
                return result
            }
        }
    }

    func dbPut(refs: [FXDataID], data: FXByteBuffer, importSize: Int?, _ ctx: Context)
        -> FXFuture<FXDataID>
    {
        stats.uploadsProgressObjects_.wrappingIncrement(ordering: .relaxed)
        stats.uploadsProgressBytes_.wrappingIncrement(by: data.readableBytes, ordering: .relaxed)
        return _db.put(refs: refs, data: data, ctx).map { result in
            guard self.finalResultPromise.isCompleted == false else {
                return result
            }
            let stats = self.stats
            stats.uploadsProgressObjects_.wrappingDecrement(ordering: .relaxed)
            stats.uploadsProgressBytes_.wrappingDecrement(
                by: data.readableBytes, ordering: .relaxed)
            stats.uploadedBytes_.wrappingIncrement(by: data.readableBytes, ordering: .relaxed)
            if let size = importSize {
                // Objects = file objects/chunks. We only count them
                // if the import size is available, indicating the
                // [near] final put.
                stats.uploadedObjects_.wrappingIncrement(ordering: .relaxed)
                stats.importedObjects_.wrappingIncrement(ordering: .relaxed)
                stats.importedBytes_.wrappingIncrement(by: size, ordering: .relaxed)
            }
            return result
        }
    }

    func relative(_ path: AbsolutePath) -> String {
        return path.prettyPath(cwd: importPath)
    }

    init(
        importPath: AbsolutePath, to db: any FXCASDatabase, options: FXCASFileTree.ImportOptions,
        stats: FXCASFileTree.ImportProgressStats, netConcurrency: Int
    ) {
        let loop = db.group.next()

        let solidStateDriveParallelism = min(8, System.coreCount)
        let cpuBoundParallelism = System.coreCount

        self.ssdQueue =
            options.sharedQueueSSD
            ?? .init(
                name: "ssdQueue", group: loop,
                maxConcurrentOperationCount: solidStateDriveParallelism)
        self.netQueue =
            options.sharedQueueNetwork
            ?? .init(maxConcurrentOperations: netConcurrency, maxConcurrentShares: 42_000_000)
        self.cpuQueue =
            options.sharedQueueCPU
            ?? .init(
                name: "cpuQueue", group: loop, maxConcurrentOperationCount: cpuBoundParallelism)

        self.finalResultPromise = LLBCancellablePromise(
            promise: loop.makePromise(of: FXDataID.self))
        self.options = options
        self.stats = stats
        self._db = db
        self.loop = loop
        self.importPath = importPath
    }

    typealias ImportError = FXCASFileTree.ImportError

    /// Make the filter that converts absolute paths into relative paths
    /// with "/" representing the `importPath` itself, and wrap a user-supplied
    /// filter function by calling it with that relative path.
    private func makePathFilter() -> ((AbsolutePath, FilesystemObjectType) -> Bool)? {
        guard let userFilter = options.pathFilter else {
            // No filter - don't give one to the concurrent scanner.
            return nil
        }

        let importDirPrefix: String = importPath.pathString + "/"
        let importDirPrefixLength = importDirPrefix.count

        func invokeUserFilter(_ path: AbsolutePath, _ type: FilesystemObjectType) -> Bool {
            let pathString = path.pathString

            guard pathString.hasPrefix(importDirPrefix) else {
                // The import path itself is automatically admissible.
                // Don't allow users to override it. We should be able to
                // import empty dirs.
                // Everything else (dirs outside `importPath`) can't happen,
                // so prohibit them just in case.
                return path == importPath
            }

            let relative = pathString.suffix(
                from: pathString.index(pathString.startIndex, offsetBy: importDirPrefixLength - 1))

            guard userFilter(String(relative)) else {
                return false
            }

            return true
        }

        return invokeUserFilter
    }

    func run(_ ctx: Context) -> FXFuture<FXDataID> {
        let loop = self.loop
        let importPath = self.importPath
        let stats = self.stats

        ssdQueue.execute({ () -> ConcurrentFilesystemScanner in
            self.set(phase: .AssemblingPaths)
            return try ConcurrentFilesystemScanner(importPath, pathFilter: self.makePathFilter())
        }).map { scanner -> [FXFuture<[ConcurrentFilesystemScanner.Element]>] in
            if TSCBasic.localFileSystem.isFile(importPath) {
                // We can import individual files just fine.
                stats.toImportObjects_.wrappingIncrement(ordering: .relaxed)
                return [loop.makeSucceededFuture([(importPath, .REG)])]
            } else {
                // Scan the filesystem tree using multiple threads.
                return (0..<self.ssdQueue.maxOpCount).map { _ in
                    self.execute(on: self.ssdQueue, default: []) {
                        () -> [ConcurrentFilesystemScanner.Element] in
                        // Gather all the paths up front.
                        var pathInfos = [ConcurrentFilesystemScanner.Element]()
                        for pathInfo in scanner {
                            pathInfos.append(pathInfo)
                            stats.toImportObjects_.wrappingIncrement(ordering: .relaxed)
                        }
                        return pathInfos
                    }
                }
            }
        }.flatMap { pathsFutures -> FXFuture<[[ConcurrentFilesystemScanner.Element]]> in
            self.whenAllSucceed(pathsFutures)
        }.map { (pathInfos: [[ConcurrentFilesystemScanner.Element]]) -> [FXFuture<NextStep>] in
            self.set(phase: .EstimatingSize)

            // Immediately slurp/verify the blobs.
            return pathInfos.joined().map { pathInfo -> FXFuture<NextStep> in
                self.execute(on: self.ssdQueue, default: .skipped) {
                    do {
                        switch try self.makeNextStep(path: pathInfo.path, type: pathInfo.type, ctx)
                        {
                        case .execute(in: .EstimatingSize, let run):
                            return NextStep.wait(in: .EstimatingSize, futures: [run()])
                        case let step:
                            return step
                        }
                    } catch {
                        _ = self.finalResultPromise.fail(error)
                        throw error
                    }
                }
            }
        }.flatMap { nextStepFutures -> FXFuture<[NextStep]> in
            self.whenAllSucceed(nextStepFutures)
        }.flatMap { nextStepFutures -> FXFuture<[NextStep]> in
            self.set(phase: .CheckIfUploaded)
            return self.recursivelyPerformSteps(
                currentPhase: .CheckIfUploaded, currentPhaseSteps: nextStepFutures)
        }.map {
            nextSteps -> (
                directoryPaths: [(AbsolutePath, LLBPosixFileDetails?)],
                completeFiles: [AbsolutePath: SingleFileInfo]
            ) in
            self.set(phase: .UploadingDirs)
            var completeFiles = [AbsolutePath: SingleFileInfo]()
            var directoryPaths = [(AbsolutePath, LLBPosixFileDetails?)]()
            for step in nextSteps {
                switch step {
                case .skipped, .partialFileChunk:
                    continue
                case .gotDirectory(let path, let posixDetails):
                    directoryPaths.append((path, posixDetails))
                case .singleFile(let info):
                    completeFiles[info.path] = info
                case .execute, .wait:
                    fatalError("Impossible step: \(step)")
                }
            }

            return (directoryPaths, completeFiles)
        }.flatMap { args -> FXFuture<FXDataID> in
            // Account for the importPath which we add here last.
            let directoryPaths = args.directoryPaths.sorted(by: { $1.0 < $0.0 })
            let completeFiles = args.completeFiles

            /// If imported a single file, return it.
            if directoryPaths.isEmpty,
                let (_, firstFile) = completeFiles.first, completeFiles.count == 1
            {
                self.set(phase: .ImportSucceeded)
                return loop.makeSucceededFuture(firstFile.id)
            }

            let udpLock = NIOConcurrencyHelpers.NIOLock()
            var uploadedDirectoryPaths_ = [
                AbsolutePath: FXFuture<(FXDataID, LLBDirectoryEntry)?>
            ]()

            // Now we have to add all the directories; we do so serially and in
            // reverse order of depth, so we can guarantee the children are resolved
            // when they need to be.
            let dirFutures: [FXFuture<Void>] = directoryPaths.map { arguments in
                let (path, pathPosixDetails) = arguments
                let dirLoop = self._db.group.next()
                let directoryPromise: FXPromise<(FXDataID, LLBDirectoryEntry)?>
                directoryPromise = dirLoop.makePromise()
                udpLock.withLockVoid {
                    uploadedDirectoryPaths_[path] = directoryPromise.futureResult
                }

                let dirFuture: FXFuture<(FXDataID, LLBDirectoryEntry)?>
                dirFuture = self.execute(on: self.netQueue, loop: dirLoop, size: 1024, default: nil)
                {
                    // Get the list of all subpaths.
                    let directoryListing: [String]
                    do {
                        directoryListing = try TSCBasic.localFileSystem.getDirectoryContents(path)
                            .sorted()
                    } catch {
                        if self.options.skipUnreadable {
                            return dirLoop.makeSucceededFuture(nil)
                        }
                        return dirLoop.makeFailedFuture(ImportError.unreadableDirectory(path))
                    }

                    // Build the finalized directory file list.
                    let subpathsFutures: [FXFuture<(FXDataID, LLBDirectoryEntry)?>]
                    subpathsFutures = directoryListing.compactMap {
                        filename -> FXFuture<(FXDataID, LLBDirectoryEntry)?> in
                        let subpath = path.appending(component: filename)

                        if let info = completeFiles[subpath] {
                            var dirEntry = LLBDirectoryEntry()
                            dirEntry.name = filename
                            dirEntry.type = info.type
                            dirEntry.size = info.size
                            dirEntry.update(posixDetails: info.posixDetails, options: self.options)
                            return dirLoop.makeSucceededFuture((info.id, dirEntry))
                        } else if let dirInfoFuture = udpLock.withLock({
                            uploadedDirectoryPaths_[subpath]
                        }) {
                            return dirInfoFuture.map { idInfo in
                                guard let (id, info) = idInfo else { return nil }
                                var dirEntry = LLBDirectoryEntry()
                                dirEntry.name = filename
                                dirEntry.type = info.type
                                dirEntry.size = info.size
                                dirEntry.update(
                                    posixDetails: info.posixDetails, options: self.options)
                                return (id, dirEntry)
                            }
                        } else {
                            return dirLoop.makeSucceededFuture(nil)
                        }
                    }

                    return self.whenAllSucceed(subpathsFutures, on: dirLoop).flatMap { subpaths in
                        do {
                            let (refs, dirData, aggregateSize) =
                                try self.constructDirectoryContents(
                                    subpaths, wireFormat: self.options.wireFormat)

                            stats.toImportBytes_.wrappingIncrement(
                                by: dirData.readableBytes, ordering: .relaxed)
                            return self.dbPut(
                                refs: refs, data: dirData, importSize: dirData.readableBytes, ctx
                            ).map { id in
                                stats.uploadedMetadataBytes_.wrappingIncrement(
                                    by: dirData.readableBytes, ordering: .relaxed)
                                var dirEntry = LLBDirectoryEntry()
                                dirEntry.name = path.pathString
                                dirEntry.type = .directory
                                dirEntry.size = aggregateSize
                                if let pd = pathPosixDetails {
                                    dirEntry.update(posixDetails: pd, options: self.options)
                                }
                                return (id, dirEntry)
                            }
                        } catch {
                            return loop.makeFailedFuture(error)
                        }
                    }
                }
                dirFuture.cascade(to: directoryPromise)
                return dirFuture.map({ _ in () })
            }

            guard let topDirFuture = udpLock.withLock({ uploadedDirectoryPaths_[importPath] })
            else {
                return loop.makeFailedFuture(ImportError.unreadableDirectory(importPath))
            }

            return self.whenAllSucceed(dirFutures).flatMap { _ -> FXFuture<FXDataID> in
                return topDirFuture.flatMapThrowing { idInfo -> FXDataID in
                    guard let (id, info) = idInfo else {
                        throw ImportError.unreadableDirectory(importPath)
                    }
                    if self.options.pathFilter != nil {
                        assert(
                            stats.importedBytes - stats.uploadedMetadataBytes == info.size,
                            "bytesImported: \(stats.importedBytes) != aggregateSize: \(info.size)")
                    }
                    self.set(phase: .ImportSucceeded)
                    return id
                }
            }
        }.flatMapErrorThrowing { error in
            _ = self.finalResultPromise.fail(error)
            throw error
        }.cascade(to: finalResultPromise)

        return finalResultPromise.futureResult.flatMapErrorThrowing { error in
            stats.phase = .ImportFailed
            throw error
        }.map { result in
            stats.phase = .ImportSucceeded
            return result
        }
    }

    // Set phase unless `finalResultPromise` is completed.
    // Allows resetting the stats between failed `import` runs without old
    // stuff stray futures the phase.
    private func set(phase: FXCASFileTree.ImportPhase) {
        if finalResultPromise.isCompleted == false {
            stats.phase = phase
        }
    }

    func recursivelyPerformSteps(
        currentPhase: FXCASFileTree.ImportPhase, currentPhaseSteps: [NextStep],
        nextPhaseSteps: [NextStep] = []
    ) -> FXFuture<[NextStep]> {
        let loop = self.loop
        var finishedSteps = [NextStep]()
        var waitInCurrentPhase = [FXFuture<NextStep>]()
        var nextPhaseSteps = nextPhaseSteps

        guard finalResultPromise.isCompleted == false else {
            return loop.makeSucceededFuture([])
        }

        for step in currentPhaseSteps {
            switch step {
            case .skipped, .partialFileChunk:
                continue
            case .singleFile, .gotDirectory:
                finishedSteps.append(step)
            case .execute(in: let phase, let run) where phase <= currentPhase:
                waitInCurrentPhase.append(run())
            case .wait(in: let phase, let futures) where phase <= currentPhase:
                waitInCurrentPhase.append(contentsOf: futures)
            case .execute, .wait:
                nextPhaseSteps.append(step)
            }
        }

        // Wait for the steps we need to wait in this phase, and then
        // advance the phase if there are no more steps to wait.
        return self.whenAllSucceed(waitInCurrentPhase).flatMap { moreStepsInCurrentPhase in
            if moreStepsInCurrentPhase.isEmpty {
                precondition(!currentPhase.isFinalPhase)  // Avoid infinite recursion
                let nextPhase = FXCASFileTree.ImportPhase(rawValue: currentPhase.rawValue + 1)!
                guard nextPhase < .UploadingDirs else {
                    return loop.makeSucceededFuture(finishedSteps + nextPhaseSteps)
                }
                self.set(phase: nextPhase)
                return self.recursivelyPerformSteps(
                    currentPhase: nextPhase, currentPhaseSteps: nextPhaseSteps
                ).map {
                    finishedSteps + $0
                }
            } else {
                return self.recursivelyPerformSteps(
                    currentPhase: currentPhase, currentPhaseSteps: moreStepsInCurrentPhase,
                    nextPhaseSteps: nextPhaseSteps
                ).map {
                    finishedSteps + $0
                }
            }
        }
    }

    struct SingleFileInfo {
        let path: AbsolutePath
        let id: FXDataID
        let type: LLBFileType
        let size: UInt64
        let posixDetails: LLBPosixFileDetails
    }

    struct AnnotatedSegment {
        let isCompressed: Bool
        let uncompressedSize: Int
        let data: LLBFastData
    }

    struct SegmentDescriptor {
        let isCompressed: Bool
        let uncompressedSize: Int
        let id: FXFuture<FXDataID>

        init(isCompressed: Bool, uncompressedSize: Int, id: FXFuture<FXDataID>) {
            self.isCompressed = isCompressed
            self.uncompressedSize = uncompressedSize
            self.id = id
        }

        init(of segment: AnnotatedSegment, id: FXFuture<FXDataID>) {
            self.isCompressed = segment.isCompressed
            self.uncompressedSize = segment.uncompressedSize
            self.id = id
        }
    }

    /// Compress segments. If some segments are not compressible, the rest
    /// of the sequence won't be compressed either.
    func maybeCompressSegments(_ segmentsIn: [LLBFastData], allocator: FXByteBufferAllocator)
        -> [AnnotatedSegment]
    {
        var useCompression = true
        return segmentsIn.map { segment in
            guard useCompression,
                let compressedSegment = try? segment.compressed(allocator: allocator)
            else {
                useCompression = false
                return AnnotatedSegment(
                    isCompressed: false, uncompressedSize: segment.count, data: segment)
            }
            return AnnotatedSegment(
                isCompressed: true, uncompressedSize: segment.count, data: compressedSegment)
        }
    }

    indirect enum NextStep {
        // Final step in a sequence: stop stepping through.
        case skipped
        // Final step: information about the file.
        case singleFile(SingleFileInfo)
        // Final step: information about the directory.
        case gotDirectory(path: AbsolutePath, posixDetails: LLBPosixFileDetails?)
        // Intermediate step: not earlier than in the given phase.
        case execute(in: FXCASFileTree.ImportPhase, run: () -> FXFuture<NextStep>)
        // This future has to be picked up in the given phase.
        case wait(in: FXCASFileTree.ImportPhase, futures: [FXFuture<NextStep>])
        // Intermediate result.
        case partialFileChunk(FXDataID)
    }

    func describeAllSegments(of file: FileSegmenter, _ ctx: Context) throws -> [SegmentDescriptor] {
        var descriptions: [SegmentDescriptor] = []

        for segmentNumber in (0...Int.max) {
            let (data, isEOF): (LLBFastData, Bool)
            do {
                guard let value = try file.fetchSegment(segmentNumber: segmentNumber) else {
                    // File EOF'ed prematurely.
                    if self.options.relaxConsistencyChecks {
                        return descriptions
                    } else {
                        throw FileSegmenter.Error.resourceChanged(reason: "Can't read")
                    }
                }
                (data, isEOF) = value
            } catch FileSegmenter.Error.resourceChanged(let reason) {
                // Translate this resource consistency error,
                // will throw all the rest as is.
                throw ImportError.modifiedFile(file.path, reason: reason)
            }

            var useCompression: Bool
            if case .compressed = options.wireFormat, file.size > 1024,
                !file.path.looksLikeCompressed, options.compressBufferAllocator != nil
            {
                useCompression = true
            } else {
                useCompression = false
            }

            let segment: AnnotatedSegment
            if useCompression,
                let compressedSegment = try? data.compressed(
                    allocator: options.compressBufferAllocator!)
            {

                segment = AnnotatedSegment(
                    isCompressed: true, uncompressedSize: data.count, data: compressedSegment)
            } else {
                useCompression = false
                segment = AnnotatedSegment(
                    isCompressed: false, uncompressedSize: data.count, data: data)
            }

            descriptions.append(
                .init(
                    of: segment, id: _db.identify(refs: [], data: segment.data.toByteBuffer(), ctx))
            )
            if isEOF {
                break
            }
        }
        assert(descriptions.reduce(0, { acc, d in acc + d.uncompressedSize }) == file.size)
        return descriptions
    }

    func prepareSingleSegment(of file: FileSegmenter, segmentNumber: Int, useCompression: Bool)
        throws -> LLBFastData
    {

        let rawData: LLBFastData
        // Any error from fetchSegment in this function is a .modifiedFile
        // error: we did read this file before and it was ok!
        // We throw this error even under relaxConsistencyChecks, and
        // check it in location /EC1.
        do {
            guard let (data, _) = try file.fetchSegment(segmentNumber: segmentNumber) else {
                throw ImportError.modifiedFile(file.path, reason: "Can't reopen")
            }
            rawData = data
        } catch FileSegmenter.Error.resourceChanged(let reason) {
            throw ImportError.modifiedFile(file.path, reason: reason)
        } catch {
            throw ImportError.modifiedFile(file.path, reason: "\(error)")
        }

        guard useCompression else {
            return rawData
        }

        return try rawData.compressed(allocator: options.compressBufferAllocator!)
    }

    func makeNextStep(path: AbsolutePath, type pathObjectType: FilesystemObjectType, _ ctx: Context)
        throws -> NextStep
    {
        let loop = self.loop
        let stats = self.stats

        let segmentDescriptors: [SegmentDescriptor]  // Information about segments of file, possibly after compression.
        let type: LLBFileType
        let allSegmentsUncompressedDataSize: Int
        enum ObjectToImport {
            case link(target: LLBFastData)
            case file(file: FileSegmenter, posixDetails: LLBPosixFileDetails)
            var posixDetails: LLBPosixFileDetails {
                switch self {
                case .link:
                    return LLBPosixFileDetails()
                case .file(_, let posixDetails):
                    return posixDetails
                }
            }
        }
        let importObject: ObjectToImport

        func relative(_ path: AbsolutePath) -> String {
            return path.prettyPath(cwd: importPath)
        }

        // If this is a symbolic link, the "data" is the target.
        switch pathObjectType {
        case .LNK:
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = TSCLibc.readlink(path.pathString, &buf, buf.count - 1)
            guard count > 0 else {
                throw ImportError.unreadableLink(path)
            }
            type = .symlink

            let target = LLBFastData(buf[..<count].map { UInt8(bitPattern: $0) })
            allSegmentsUncompressedDataSize = target.count
            importObject = .link(target: target)
            segmentDescriptors = [
                SegmentDescriptor(
                    isCompressed: false, uncompressedSize: target.count,
                    id: _db.identify(refs: [], data: target.toByteBuffer(), ctx))
            ]
        case .DIR:
            let posixDetails: LLBPosixFileDetails?

            // Read the permissions and ownership information, if requested.
            if options.preservePosixDetails.preservationEnabled {
                var sb = stat()
                if lstat(path.pathString, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFDIR {
                    posixDetails = LLBPosixFileDetails(from: sb)
                } else {
                    posixDetails = nil
                }
            } else {
                posixDetails = nil
            }

            // If this is a directory, defer its processing.
            return .gotDirectory(path: path, posixDetails: posixDetails)
        case .REG:
            let file: FileSegmenter
            do {
                file = try FileSegmenter(
                    importPath: importPath, path, segmentSize: options.fileChunkSize,
                    minMmapSize: options.minMmapSize,
                    allowInconsistency: options.relaxConsistencyChecks)
            } catch {
                guard options.skipUnreadable else {
                    throw ImportError.unreadableFile(path)
                }
                return .skipped
            }

            type = (file.statInfo.st_mode & 0o111 == 0) ? .plainFile : .executable
            importObject = .file(file: file, posixDetails: LLBPosixFileDetails(from: file.statInfo))
            segmentDescriptors = try describeAllSegments(of: file, ctx)
            allSegmentsUncompressedDataSize = segmentDescriptors.reduce(0) {
                $0 + $1.uncompressedSize
            }
        default:
            return .skipped
        }

        // Add the rest of the chunks to the number of objects to import.
        stats.toImportObjects_.wrappingIncrement(
            by: max(0, allSegmentsUncompressedDataSize - 1) / options.fileChunkSize,
            ordering: .relaxed)
        stats.toImportBytes_.wrappingIncrement(
            by: allSegmentsUncompressedDataSize, ordering: .relaxed)
        stats.toImportFiles_.wrappingIncrement(ordering: .relaxed)

        // We check if the remote contains the object before ingesting.
        //
        // FIXME: This feels like it should be automatically handled by
        // the database, not here. For now, the RemoteCASDatabase isn't
        // doing this, though, so this is important for avoiding
        // unnecessary uploads.
        // FIXME: Double-scanning of files on disk.

        // Whether the file is stored as a single chunk.
        let isSingleChunk = segmentDescriptors.count == 1

        // Whether the current object is top level of the whole tree.
        // Can happen if the file is a sole object to import.
        let topLevel = isSingleChunk && importPath == path

        func assemblePartialNextSteps() -> [FXFuture<NextStep>] {
            let cheapNextAndPartialStepFutures:
                [(nextStepFuture: FXFuture<NextStep>, partialStepFuture: FXFuture<NextStep>)] =
                    segmentDescriptors.enumerated().map { (segmentOffset, segm) in

                        // This partial step is a final step for the sequence
                        // of cheap/heavy steps, for a single segment (chunk).
                        // We use cancellable promise since our heavy next steps might
                        // not even run at all.
                        let partialStepPromise = LLBCancellablePromise(
                            promise: loop.makePromise(of: NextStep.self))

                        func encodeNextStep(for id: FXDataID) -> NextStep {
                            if isSingleChunk {
                                return .singleFile(
                                    SingleFileInfo(
                                        path: path, id: id, type: type,
                                        size: UInt64(clamping: segm.uncompressedSize),
                                        posixDetails: importObject.posixDetails))
                            } else {
                                return .partialFileChunk(id)
                            }
                        }

                        // If the file has non-standard layout, upload it after we upload
                        // the binary blob.
                        func uploadFileInfo(blobId: FXDataID, importSize: Int? = nil) -> FXFuture<
                            NextStep
                        > {
                            guard finalResultPromise.isCompleted == false else {
                                return loop.makeSucceededFuture(NextStep.skipped)
                            }

                            // We need to wrap the blob in a `FileInformation`:
                            // — When we compress the file.
                            // — When the file is top level (importing a single file).
                            guard segm.isCompressed || topLevel else {
                                if let size = importSize {
                                    stats.importedObjects_.wrappingIncrement(ordering: .relaxed)
                                    stats.importedBytes_.wrappingIncrement(
                                        by: size, ordering: .relaxed)
                                }
                                return loop.makeSucceededFuture(encodeNextStep(for: blobId))
                            }

                            var fileInfo = LLBFileInfo()
                            // Each segment (if not a single segment) is encoded as a plain
                            // file and doesn't have any other metadata (e.g. permissions).
                            if isSingleChunk {
                                fileInfo.type = type
                                fileInfo.update(
                                    posixDetails: importObject.posixDetails, options: self.options)
                            } else {
                                fileInfo.type = .plainFile
                            }
                            fileInfo.size = UInt64(segm.uncompressedSize)
                            // FIXME: no compression supported right now
                            // fileInfo.compression = segm.isCompressed ? ... : .none
                            assert(!segm.isCompressed)
                            fileInfo.compression = .none
                            fileInfo.fixedChunkSize = UInt64(segm.uncompressedSize)
                            do {
                                return dbPut(
                                    refs: [blobId], data: try fileInfo.toBytes(),
                                    importSize: importSize, ctx
                                ).map { id in
                                    encodeNextStep(for: id)
                                }
                            } catch {
                                return loop.makeFailedFuture(error)
                            }
                        }

                        let containsRequestWireSizeEstimate = 64

                        let throttledContainsFuture = self.execute(
                            on: self.netQueue, size: containsRequestWireSizeEstimate,
                            default: .skipped
                        ) { () -> FXFuture<NextStep> in
                            let containsFuture = self.dbContains(segm, ctx)
                            let containsLoop = containsFuture.eventLoop
                            return containsFuture.flatMap { exists -> FXFuture<NextStep> in

                                guard !exists else {
                                    let existingIdFuture: FXFuture<NextStep> = segm.id.flatMap {
                                        id in
                                        return uploadFileInfo(
                                            blobId: id, importSize: segm.uncompressedSize)
                                    }
                                    existingIdFuture.cascade(to: partialStepPromise)
                                    return existingIdFuture
                                }

                                return containsLoop.makeSucceededFuture(
                                    NextStep.execute(
                                        in: .UploadingFiles,
                                        run: {
                                            let nextStepFuture: FXFuture<NextStep> = self.execute(
                                                on: self.cpuQueue, default: nil
                                            ) { () -> FXFuture<NextStep>? in
                                                let data: LLBFastData

                                                switch importObject {
                                                case .link(let target):
                                                    data = target
                                                case .file(let file, _):
                                                    data = try self.prepareSingleSegment(
                                                        of: file, segmentNumber: segmentOffset,
                                                        useCompression: segm.isCompressed)
                                                }

                                                let slice = data.toByteBuffer()

                                                // Make sure we want until the netQueue is sufficiently
                                                // free to take our load. This ensures that we're not
                                                // limited by CPU parallelism for network concurrency.
                                                return self.executeWithBackpressure(
                                                    on: self.netQueue, loop: containsLoop,
                                                    size: slice.readableBytes, default: .skipped
                                                ) { () -> FXFuture<NextStep> in
                                                    return self.dbPut(
                                                        refs: [], data: slice,
                                                        importSize: segm.uncompressedSize, ctx
                                                    ).flatMap { id -> FXFuture<NextStep> in
                                                        withExtendedLifetime(importObject) {  // for mmap
                                                            uploadFileInfo(blobId: id)
                                                        }
                                                    }.map { result in
                                                        return result
                                                    }.hop(to: loop)
                                                }
                                            }.flatMap {
                                                // This type of return ensures that cpuQueue does not
                                                // wait for the netQueue operation to complete.
                                                $0 ?? loop.makeSucceededFuture(NextStep.skipped)
                                            }
                                            nextStepFuture.cascade(to: partialStepPromise)
                                            return nextStepFuture
                                        }))
                            }
                        }

                        return (
                            nextStepFuture: throttledContainsFuture,
                            partialStepFuture: partialStepPromise.futureResult
                        )
                    }

            let cheapNextStepFutures: [FXFuture<NextStep>] = cheapNextAndPartialStepFutures.map {
                $0.nextStepFuture
            }

            // Sending a single segment, for which we don't need
            // to wait until all of its subcomponents are uploaded.
            guard isSingleChunk == false else {
                return cheapNextStepFutures
            }

            let partialStepFutures = cheapNextAndPartialStepFutures.map { $0.partialStepFuture }
            let combinePartialResultsStep: NextStep = NextStep.execute(
                in: .UploadingWait,
                run: {
                    return self.whenAllSucceed(partialStepFutures).flatMapErrorThrowing {
                        error -> [NextStep] in
                        // If ready any segment fails with something, we either forward
                        // the error or hide it.

                        if error is FileSystemError {
                            // Some kind of filesystem access error.
                            if self.options.skipUnreadable {
                                return []
                            }
                        } else if let fsError = error as? FileSegmenter.Error {
                            if case .resourceChanged = fsError {
                                if self.options.relaxConsistencyChecks {
                                    // Turn consistency checks errors into skips.
                                    // Location /EC1.
                                    return []
                                }
                            }
                        } else if error is FileSystemError {
                            if self.options.skipUnreadable {
                                // Not a consistency error, hide it.
                                return []
                            }
                        }

                        throw error

                    }.flatMap { nextSteps in
                        // The next steps can only be empty if we've reacting on
                        // a filesystem-related error with some of our chunks.
                        guard nextSteps.isEmpty == false else {
                            return loop.makeSucceededFuture(.skipped)
                        }

                        let chunkIds: [FXDataID] = nextSteps.map {
                            guard case .partialFileChunk(let id) = $0 else {
                                preconditionFailure("Next step is not a partial chunk")
                            }
                            return id
                        }

                        var fileInfo = LLBFileInfo()
                        fileInfo.type = type
                        fileInfo.size = UInt64(allSegmentsUncompressedDataSize)
                        // The top is not compressed when chunks are present.
                        fileInfo.compression = .none
                        fileInfo.fixedChunkSize = UInt64(
                            chunkIds.count > 1
                                ? self.options.fileChunkSize : allSegmentsUncompressedDataSize)
                        let posixDetails = importObject.posixDetails
                        fileInfo.update(posixDetails: posixDetails, options: self.options)
                        do {
                            let fileInfoBytes = try fileInfo.toBytes()
                            return self.execute(
                                on: self.netQueue, size: fileInfoBytes.readableBytes,
                                default: .skipped
                            ) {
                                self.dbPut(
                                    refs: chunkIds, data: fileInfoBytes, importSize: nil, ctx
                                ).map { id in
                                    return .singleFile(
                                        SingleFileInfo(
                                            path: path, id: id, type: type,
                                            size: UInt64(clamping: allSegmentsUncompressedDataSize),
                                            posixDetails: posixDetails))
                                }
                            }
                        } catch {
                            return loop.makeFailedFuture(error)
                        }
                    }
                })

            // Since uploading fragmented files requires waiting and churning
            // the recursive next step machinery until the parts are properly
            // uploaded, we can't just block on waiting until all the chunks
            // have been uploaded. Therefore we wait for the huge files in
            // its own state, .UploadingWait.
            return cheapNextStepFutures + [loop.makeSucceededFuture(combinePartialResultsStep)]
        }

        // When the .EstimatingSize phase comes, this can be executed.
        return .execute(
            in: .EstimatingSize,
            run: {
                loop.makeSucceededFuture(
                    NextStep.wait(
                        in: .CheckIfUploaded,
                        futures: assemblePartialNextSteps()))
            })
    }

    /// Construct the bytes representing the directory contents.
    func constructDirectoryContents(
        _ subpaths: [(FXDataID, LLBDirectoryEntry)?], wireFormat: FXCASFileTree.WireFormat
    ) throws -> (refs: [FXDataID], dirData: FXByteBuffer, aggregateSize: UInt64) {
        var refs = [FXDataID]()
        let dirData: FXByteBuffer
        var aggregateSize: UInt64 = 0

        switch wireFormat {
        case .binary, .compressed:
            /// We don't employ compression for directory entries yet,
            /// so both .binary and .compression just use the
            /// NamedDirectoryEntries encoded using the Protobuf encoding.
            var dirEntries = LLBDirectoryEntries()
            dirEntries.entries = subpaths.compactMap { args in
                guard let (id, info) = args else { return nil }
                refs.append(id)
                let (partial, overflow) = aggregateSize.addingReportingOverflow(info.size)
                aggregateSize = partial
                // Ignore overflow for now, otherwise.
                assert(!overflow)
                return info
            }

            var dirNode = LLBFileInfo()
            dirNode.type = .directory
            dirNode.size = aggregateSize
            dirNode.compression = .none
            dirNode.inlineChildren = dirEntries
            dirData = try dirNode.toBytes()
        }

        return (refs, dirData, aggregateSize)
    }

    private func whenAllSucceed<Value>(
        _ futures: [FXFuture<Value>], on loop: FXFuturesDispatchLoop? = nil
    ) -> FXFuture<[Value]> {
        let loop = loop ?? self.loop
        guard finalResultPromise.isCompleted == false else {
            return loop.makeSucceededFuture([])
        }
        return FXFuture.whenAllSucceed(futures, on: loop).map { result in
            guard self.finalResultPromise.isCompleted == false else {
                return []
            }
            return result
        }.flatMapErrorThrowing { error in
            _ = self.finalResultPromise.fail(error)
            throw error
        }
    }

    /// Enqueue the callback unless the stop flag is in action.
    /// If stop flag is set, return the value specified in `then`.
    private func execute<T>(
        on queue: LLBBatchingFutureOperationQueue, default stopValue: T,
        _ body: @escaping () throws -> T
    ) -> FXFuture<T> {
        guard finalResultPromise.isCompleted == false else {
            return queue.group.next().makeSucceededFuture(stopValue)
        }
        return queue.execute {
            guard self.finalResultPromise.isCompleted == false else {
                return stopValue
            }
            do {
                return try body()
            } catch {
                _ = self.finalResultPromise.fail(error)
                throw error
            }
        }
    }

    /// Enqueue the callback unless the stop flag is in action.
    /// If stop flag is set, return the value specified in `then`.
    private func execute<T>(
        on queue: FXFutureOperationQueue, loop: EventLoop? = nil, size: Int = 1,
        default stopValue: T, _ body: @escaping () -> FXFuture<T>
    ) -> FXFuture<T> {
        let loop = loop ?? self.loop
        guard finalResultPromise.isCompleted == false else {
            return loop.makeSucceededFuture(stopValue)
        }
        return queue.enqueue(on: loop, share: size) {
            guard self.finalResultPromise.isCompleted == false else {
                return loop.makeSucceededFuture(stopValue)
            }
            return body().flatMapErrorThrowing { error in
                _ = self.finalResultPromise.fail(error)
                throw error
            }
        }
    }

    // NB: does .wait(), therefore only safe on BatchingFutureOperationQueue.
    @available(
        *, noasync,
        message: "This method blocks indefinitely, don't use from 'async' or SwiftNIO EventLoops"
    )
    @available(*, deprecated, message: "This method blocks indefinitely and returns a future")
    private func executeWithBackpressure<T>(
        on queue: FXFutureOperationQueue, loop: FXFuturesDispatchLoop, size: Int = 1,
        default stopValue: T, _ body: @escaping () -> FXFuture<T>
    ) -> FXFuture<T> {
        guard finalResultPromise.isCompleted == false else {
            return loop.makeSucceededFuture(stopValue)
        }
        return queue.enqueueWithBackpressure(on: loop, share: size) {
            guard self.finalResultPromise.isCompleted == false else {
                return loop.makeSucceededFuture(stopValue)
            }
            return body().flatMapErrorThrowing { error in
                _ = self.finalResultPromise.fail(error)
                throw error
            }
        }
    }

}

extension LLBFastData {
    func compressed(allocator: FXByteBufferAllocator) throws -> LLBFastData {
        throw FXCASFileTree.ImportError.compressionFailed("unsupported")
    }
}

extension LLBFastData {
    internal func toByteBuffer() -> FXByteBuffer {
        switch self {
        case .view(let data):
            return data
        case .slice, .data, .pointer:
            var buffer = FXByteBufferAllocator().buffer(capacity: count)
            return withContiguousStorage { fromPtr in
                buffer.writeBytes(fromPtr)
                return buffer
            }
        }
    }
}

extension AbsolutePath {
    // Don't bother compressing compressed content.
    var looksLikeCompressed: Bool {
        guard let ext = `extension`?.lowercased() else { return false }
        switch ext {
        case "aac", "mp3", "mp4", "mov",
            "jpg", "jpeg", "tiff", "tif", "png", "gif",
            "pdf", "doc", "docx",
            "gz", "tgz", "rar", "zip", "yaa", "xz",
            "dmg":
            return true
        default:
            return false
        }
    }
}

extension LLBPosixFileDetails {
    /// Return details only if details are not entirely predictable
    /// from file type and other context.
    func normalized(expectedMode: mode_t, options: FXCASFileTree.ImportOptions?)
        -> LLBPosixFileDetails?
    {

        var details = self
        if options?.preservePosixDetails.preservePosixMode == false {
            details.mode = 0
        } else if self.mode == expectedMode {
            // Mode is predictable from context.
            details.mode = 0
        }

        if options?.preservePosixDetails.preservePosixOwnership == false {
            details.owner = 0
            details.group = 0
        }

        if details == LLBPosixFileDetails() {
            return nil
        } else {
            return details
        }
    }

}

extension LLBFileInfo {

    mutating func update(posixDetails: LLBPosixFileDetails, options: FXCASFileTree.ImportOptions?)
    {
        if let details = posixDetails.normalized(
            expectedMode: type.expectedPosixMode, options: options)
        {
            self.posixDetails = details
        } else {
            self.clearPosixDetails()
        }
    }

}

extension LLBDirectoryEntry {

    package mutating func update(
        posixDetails: LLBPosixFileDetails, options: FXCASFileTree.ImportOptions?
    ) {
        if let details = posixDetails.normalized(
            expectedMode: type.expectedPosixMode, options: options)
        {
            self.posixDetails = details
        } else {
            self.clearPosixDetails()
        }
    }

}
