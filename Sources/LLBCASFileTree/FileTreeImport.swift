// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIO
import NIOConcurrencyHelpers
import TSCBasic
import TSCLibc
import ZSTD

import LLBCAS
import LLBSupport


public extension LLBCASFileTree {

    /// Serialization format.
    enum WireFormat: String, CaseIterable {
    /// Binary encoding for directory and file data
    case binary
    /// Binary encoding with data compression applied.
    case compressed
    }

    enum ImportError: Swift.Error {
        case unreadableDirectory(AbsolutePath)
        case unreadableLink(AbsolutePath)
        case unreadableFile(AbsolutePath)
        case modifiedFile(AbsolutePath, reason: String)
    }

    enum ImportPhase: Int, Comparable {
        case AssemblingPaths
        case EstimatingSize
        case CheckIfUploaded
        case UploadingFiles
        case UploadingWait
        case UploadingDirs
        case ImportFailed
        case ImportSucceeded

        /// Whether no futher phase change is going to happen.
        public var isFinalPhase: Bool {
            return self == .ImportSucceeded || self == .ImportFailed
        }

        public static func<(lhs: ImportPhase, rhs: ImportPhase) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// Modifiers for the default behavior of the `import` call.
    struct ImportOptions {
        /// The serialization format for persisting the CASTrees.
        public var wireFormat: WireFormat

        /// File chunk sizing:
        /// Empirically, a good balance between
        ///  - network transfer speed (the larger the segment the faster)
        ///  - the size of the [LLBDataID] (the larger the segment the better)
        ///  - local resource utilization (the smaller the better)
        ///  - future "random" access time to first byte latency (smaller best)
        public var fileChunkSize: Int

        /// Minimum file size to employ mmap(2).
        public var minMmapSize = Int.max

        /// Allocator for compression. If not set, a ByteBufferAllocator
        /// is going to be used if compression is requested.
        public var compressBufferAllocator: LLBByteBufferAllocator? = nil

        /// Skip unreadable files or directories.
        public var skipUnreadable = false

        /// Allow importing of data which changes mid-flight.
        /// Necessary if absolutely have to import something that has
        /// a couple of files changing all the time (logs?).
        public var relaxConsistencyChecks = false

        /// A function to check whether path name matches the
        /// expectations before importing. If the directory name does not
        /// match expectation, it is not recursed into.
        /// NB: The filter argument is an absolute path _relative to the
        /// import location_. A top level imported directory becomes "/".
        public var pathFilter: ((String) -> Bool)?

        /// Shared queues for operations that should be limited by mainly the
        /// data drive parallelism, network concurrency parallelism,
        /// and CPU parallelism.
        public var sharedQueueSSD: LLBBatchingFutureOperationQueue? = nil
        public var sharedQueueNetwork: LLBFutureOperationQueue? = nil
        public var sharedQueueCPU: LLBBatchingFutureOperationQueue? = nil

        /// Create a set of import options.
        public init(
            fileChunkSize: Int = 8 * 1024 * 1024,
            wireFormat: WireFormat = .binary
        ) {
            self.fileChunkSize = fileChunkSize
            self.wireFormat = wireFormat
        }

        /// Create a copy of the options with a particular `wireFormat`.
        public func with(wireFormat: WireFormat) -> Self {
            var opts = self
            opts.wireFormat = wireFormat
            return opts
        }
    }

    final class ImportProgressStats: CustomDebugStringConvertible {

        /// Number of plain files to import (not directories).
        let toImportFiles_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Number of objects to import.
        let toImportObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Number of bytes to import.
        let toImportBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        /// Number of objects currently being presence-checked in CAS.
        let checksProgressObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Number of bytes currently being presence-checked in CAS.
        let checksProgressBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Number of objects checked in CAS.
        let checkedObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Number of bytes checked in CAS.
        let checkedBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        /// Uploads currently in progress, objects.
        let uploadsProgressObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Uploads currently in progress, bytes.
        let uploadsProgressBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Objects moved over the wire.
        let uploadedObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Bytes moved over the wire.
        let uploadedBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Uploaded directory descriptions (not yet part of aggregateSize!)
        let uploadedMetadataBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        /// Objects ended up ended up being stored in the CAS.
        let importedObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Bytes ended up being stored in the CAS.
        let importedBytes_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        /// Execution phase
        internal let phase_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        public var toImportFiles: Int { toImportFiles_.load() }
        public var toImportObjects: Int { toImportObjects_.load() }
        public var toImportBytes: Int { toImportBytes_.load() }
        public var checksProgressObjects: Int { checksProgressObjects_.load() }
        public var checksProgressBytes: Int { checksProgressBytes_.load() }
        public var checkedObjects: Int { checkedObjects_.load() }
        public var checkedBytes: Int { checkedBytes_.load() }
        public var uploadsProgressObjects: Int { uploadsProgressObjects_.load() }
        public var uploadsProgressBytes: Int { uploadsProgressBytes_.load() }
        public var uploadedObjects: Int { uploadedObjects_.load() }
        public var uploadedBytes: Int { uploadedBytes_.load() }
        public var uploadedMetadataBytes: Int { uploadedMetadataBytes_.load() }
        public var importedObjects: Int { importedObjects_.load() }
        public var importedBytes: Int { importedBytes_.load() }

        fileprivate func reset() {
            phase_.store(0)
            toImportFiles_.store(0)
            toImportObjects_.store(0)
            toImportBytes_.store(0)
            checksProgressObjects_.store(0)
            checksProgressBytes_.store(0)
            checkedObjects_.store(0)
            checkedBytes_.store(0)
            uploadsProgressObjects_.store(0)
            uploadsProgressBytes_.store(0)
            uploadedObjects_.store(0)
            uploadedBytes_.store(0)
            uploadedMetadataBytes_.store(0)
            importedObjects_.store(0)
            importedBytes_.store(0)
        }

        public internal(set) var phase: ImportPhase {
            get { ImportPhase(rawValue: phase_.load())! }
            set {
                repeat {
                    let currentPhase = phase
                    guard !currentPhase.isFinalPhase else {
                        break   // Do not change the final state.
                    }
                    guard !phase_.compareAndExchange(expected: currentPhase.rawValue, desired: newValue.rawValue) else {
                        break   // State change succeeded.
                    }
                    // Repeat attempt if need to set the final state.
                } while newValue.isFinalPhase
                // It is OK not to be able to write not a final state;
                // the last state update wins anyway.
            }
        }

        public var debugDescription: String {
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

        public init() { }

        deinit {
            phase_.destroy()
            toImportFiles_.destroy()
            toImportObjects_.destroy()
            toImportBytes_.destroy()
            checksProgressObjects_.destroy()
            checksProgressBytes_.destroy()
            checkedObjects_.destroy()
            checkedBytes_.destroy()
            uploadsProgressObjects_.destroy()
            uploadsProgressBytes_.destroy()
            uploadedObjects_.destroy()
            uploadedBytes_.destroy()
            uploadedMetadataBytes_.destroy()
            importedObjects_.destroy()
            importedBytes_.destroy()
        }
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
    static func `import`(path importPath: AbsolutePath, to db: LLBCASDatabase, options optionsTemplate: LLBCASFileTree.ImportOptions = .init(), stats providedStats: LLBCASFileTree.ImportProgressStats? = nil) -> LLBFuture<LLBDataID> {
        let stats = providedStats ?? .init()

        // Adjust options
        var mutableOptions = optionsTemplate
        switch mutableOptions.wireFormat {
        case .compressed where mutableOptions.compressBufferAllocator == nil:
            mutableOptions.compressBufferAllocator = LLBByteBufferAllocator()
        default:
            break
        }
        let options = mutableOptions

        // Maximum number of outstanding db.contains and db.put operations.
        let initialNetConcurrency = 9_999
        return LLBCASFileTree.recursivelyDecreasingLimit(on: db.group.next(), limit: initialNetConcurrency) { limit in
            stats.reset()
            return CASTreeImport(importPath: importPath, to: db,
                        options: options, stats: stats,
                        netConcurrency: limit).run()
        }
    }

    // Retry with lesser concurrency if we see unexpected network errors.
    private static func recursivelyDecreasingLimit<T>(on loop: LLBFuturesDispatchLoop, limit: Int, _ body: @escaping (Int) -> LLBFuture<T>) -> LLBFuture<T> {
        return body(limit).flatMapError { error -> LLBFuture<T> in
            // Check if something retryable happened.
            guard case LLBCASDatabaseError.retryableNetworkError(_) = error else {
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


private final class CASTreeImport {

    let importPath: AbsolutePath
    let options: LLBCASFileTree.ImportOptions
    let stats: LLBCASFileTree.ImportProgressStats
    let ssdQueue: LLBBatchingFutureOperationQueue
    let netQueue: LLBFutureOperationQueue
    let cpuQueue: LLBBatchingFutureOperationQueue

    let loop: LLBFuturesDispatchLoop
    let _db: LLBCASDatabase
    let finalResultPromise: LLBCancellablePromise<LLBDataID>

    func dbContains(_ segm: SegmentDescriptor) -> LLBFuture<Bool> {
        _ = stats.checksProgressObjects_.add(+1)
        _ = stats.checksProgressBytes_.add(segm.uncompressedSize)
        return segm.id.flatMap { id in
            return self._db.contains(id).map { result in
                guard self.finalResultPromise.isCompleted == false else {
                    return false
                }
                let stats = self.stats
                _ = stats.checkedObjects_.add(+1)
                _ = stats.checkedBytes_.add(+segm.uncompressedSize)
                _ = stats.checksProgressObjects_.add(-1)
                _ = stats.checksProgressBytes_.add(-segm.uncompressedSize)
                return result
            }
        }
    }

    func dbPut(refs: [LLBDataID], data: LLBByteBuffer, importSize: Int?) -> LLBFuture<LLBDataID> {
        _ = stats.uploadsProgressObjects_.add(+1)
        _ = stats.uploadsProgressBytes_.add(data.readableBytes)
        return _db.put(refs: refs, data: data).map { result in
            guard self.finalResultPromise.isCompleted == false else {
                return result
            }
            let stats = self.stats
            _ = stats.uploadsProgressObjects_.add(-1)
            _ = stats.uploadsProgressBytes_.add(-data.readableBytes)
            _ = stats.uploadedBytes_.add(data.readableBytes)
            if let size = importSize {
                // Objects = file objects/chunks. We only count them
                // if the import size is available, indicating the
                // [near] final put.
                _ = stats.uploadedObjects_.add(1)
                _ = stats.importedObjects_.add(1)
                _ = stats.importedBytes_.add(size)
            }
            return result
        }
    }

    func relative(_ path: AbsolutePath) -> String {
        return path.prettyPath(cwd: importPath)
    }

    init(importPath: AbsolutePath, to db: LLBCASDatabase, options: LLBCASFileTree.ImportOptions, stats: LLBCASFileTree.ImportProgressStats, netConcurrency: Int) {
        let loop = db.group.next()

        let solidStateDriveParallelism = min(8, System.coreCount)
        let cpuBoundParallelism = System.coreCount

        self.ssdQueue = options.sharedQueueSSD ?? .init(name: "ssdQueue", group: loop, maxConcurrentOperationCount: solidStateDriveParallelism)
        self.netQueue = options.sharedQueueNetwork ?? .init(maxConcurrentOperations: netConcurrency, maxConcurrentShares: 42_000_000)
        self.cpuQueue = options.sharedQueueCPU ?? .init(name: "cpuQueue", group: loop, maxConcurrentOperationCount: cpuBoundParallelism)

        self.finalResultPromise = LLBCancellablePromise(promise: loop.makePromise(of: LLBDataID.self))
        self.options = options
        self.stats = stats
        self._db = db
        self.loop = loop
        self.importPath = importPath
    }

    typealias ImportError = LLBCASFileTree.ImportError

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

            let relative = pathString.suffix(from: pathString.index(pathString.startIndex, offsetBy: importDirPrefixLength - 1))

            guard userFilter(String(relative)) else {
                return false
            }

            return true
        }

        return invokeUserFilter
    }

    func run() -> LLBFuture<LLBDataID> {
        let loop = self.loop
        let importPath = self.importPath
        let stats = self.stats

        ssdQueue.execute({ () -> ConcurrentFilesystemScanner in
            self.set(phase: .AssemblingPaths)
            return try ConcurrentFilesystemScanner(importPath, pathFilter: self.makePathFilter())
        }).map { scanner -> [LLBFuture<[ConcurrentFilesystemScanner.Element]>] in
            if TSCBasic.localFileSystem.isFile(importPath) {
                // We can import individual files just fine.
                _ = stats.toImportObjects_.add(1)
                return [loop.makeSucceededFuture([(importPath, .REG)])]
            } else {
                // Scan the filesystem tree using multiple threads.
                return (0..<self.ssdQueue.maxOpCount).map { _ in
                  self.execute(on: self.ssdQueue, default: []) { () -> [ConcurrentFilesystemScanner.Element] in
                    // Gather all the paths up front.
                    var pathInfos = [ConcurrentFilesystemScanner.Element]()
                    for pathInfo in scanner {
                        pathInfos.append(pathInfo)
                        _ = stats.toImportObjects_.add(1)
                    }
                    return pathInfos
                  }
                }
            }
        }.flatMap { pathsFutures -> LLBFuture<[[ConcurrentFilesystemScanner.Element]]> in
            self.whenAllSucceed(pathsFutures)
        }.map { (pathInfos: [[ConcurrentFilesystemScanner.Element]]) -> [LLBFuture<NextStep>] in
            self.set(phase: .EstimatingSize)

            // Immediately slurp/verify the blobs.
            return pathInfos.joined().map { pathInfo -> LLBFuture<NextStep> in
                self.execute(on: self.ssdQueue, default: .skipped) {
                    do {
                        switch try self.makeNextStep(path: pathInfo.path, type: pathInfo.type) {
                        case let .execute(in: .EstimatingSize, run):
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
        }.flatMap { nextStepFutures -> LLBFuture<[NextStep]> in
            self.whenAllSucceed(nextStepFutures)
        }.flatMap { nextStepFutures -> LLBFuture<[NextStep]> in
            self.set(phase: .CheckIfUploaded)
            return self.recursivelyPerformSteps(currentPhase: .CheckIfUploaded, currentPhaseSteps: nextStepFutures)
        }.map { nextSteps -> (directoryPaths: [AbsolutePath], completeFiles: [AbsolutePath: SingleFileInfo]) in
            self.set(phase: .UploadingDirs)
            var completeFiles = [AbsolutePath: SingleFileInfo]()
            var directoryPaths = [AbsolutePath]()
            for step in nextSteps {
                switch step {
                case .skipped, .partialFileChunk:
                    continue
                case .gotDirectory(let path):
                    directoryPaths.append(path)
                case .singleFile(let info):
                    completeFiles[info.path] = info
                case .execute, .wait:
                    fatalError("Impossible step: \(step)")
                }
            }

            return (directoryPaths, completeFiles)
        }.flatMap { args -> LLBFuture<LLBDataID> in
            // Account for the importPath which we add here last.
            let directoryPaths = args.directoryPaths.sorted().reversed()
            let completeFiles = args.completeFiles

            /// If imported a single file, return it.
            if directoryPaths.isEmpty,
               let (_, firstFile) = completeFiles.first, completeFiles.count == 1 {
                self.set(phase: .ImportSucceeded)
                return loop.makeSucceededFuture(firstFile.id)
            }

            let udpLock = NIOConcurrencyHelpers.Lock()
            var uploadedDirectoryPaths_ = [AbsolutePath: LLBFuture<(LLBDataID, LLBDirectoryEntry)?>]()

            // Now we have to add all the directories; we do so serially and in
            // reverse order of depth, so we can guarantee the children are resolved
            // when they need to be.
            let dirFutures: [LLBFuture<Void>] = directoryPaths.map { path in
              let dirLoop = self._db.group.next()
              let directoryPromise: LLBPromise<(LLBDataID, LLBDirectoryEntry)?>
              directoryPromise = dirLoop.makePromise()
              udpLock.withLockVoid {
                uploadedDirectoryPaths_[path] = directoryPromise.futureResult
              }

              let dirFuture: LLBFuture<(LLBDataID, LLBDirectoryEntry)?>
              dirFuture = self.execute(on: self.netQueue, loop: dirLoop, size: 1024, default: nil) {
                // Get the list of all subpaths.
                let directoryListing: [String]
                do {
                    directoryListing = try TSCBasic.localFileSystem.getDirectoryContents(path).sorted()
                } catch {
                    if self.options.skipUnreadable {
                        return dirLoop.makeSucceededFuture(nil)
                    }
                    return dirLoop.makeFailedFuture(ImportError.unreadableDirectory(path))
                }

                // Build the finalized directory file list.
                let subpathsFutures: [LLBFuture<(LLBDataID, LLBDirectoryEntry)?>]
                subpathsFutures = directoryListing.compactMap { filename -> LLBFuture<(LLBDataID, LLBDirectoryEntry)?> in
                    let subpath = path.appending(component: filename)

                    if let info = completeFiles[subpath] {
                        var dirEntry = LLBDirectoryEntry()
                        dirEntry.name = filename
                        dirEntry.type = info.type
                        dirEntry.size = info.size
                        return dirLoop.makeSucceededFuture((info.id, dirEntry))
                    } else if let dirInfoFuture = udpLock.withLock({uploadedDirectoryPaths_[subpath]}) {
                        return dirInfoFuture.map { idInfo in
                            guard let (id, info) = idInfo else { return nil }
                            var dirEntry = LLBDirectoryEntry()
                            dirEntry.name = filename
                            dirEntry.type = info.type
                            dirEntry.size = info.size
                            return (id, dirEntry)
                        }
                    } else {
                        return dirLoop.makeSucceededFuture(nil)
                    }
                }

                return self.whenAllSucceed(subpathsFutures, on: dirLoop).flatMap { subpaths in
                    do {
                        let (refs, dirData, aggregateSize) = try self.constructDirectoryContents(subpaths, wireFormat: self.options.wireFormat)

                        _ = stats.toImportBytes_.add(dirData.readableBytes)
                        return self.dbPut(refs: refs, data: dirData, importSize: dirData.readableBytes).map { id in
                            _ = stats.uploadedMetadataBytes_.add(dirData.readableBytes)
                            var dirEntry = LLBDirectoryEntry()
                            dirEntry.name = path.pathString
                            dirEntry.type = .directory
                            dirEntry.size = aggregateSize
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

            guard let topDirFuture = udpLock.withLock({uploadedDirectoryPaths_[importPath]}) else {
                return loop.makeFailedFuture(ImportError.unreadableDirectory(importPath))
            }

            return self.whenAllSucceed(dirFutures).flatMap { _ -> LLBFuture<LLBDataID> in
                return topDirFuture.flatMapThrowing { idInfo -> LLBDataID in
                    guard let (id, info) = idInfo else {
                        throw ImportError.unreadableDirectory(importPath)
                    }
                    if self.options.pathFilter != nil {
                        assert(stats.importedBytes - stats.uploadedMetadataBytes == info.size, "bytesImported: \(stats.importedBytes) != aggregateSize: \(info.size)")
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
    private func set(phase: LLBCASFileTree.ImportPhase) {
        if finalResultPromise.isCompleted == false {
            stats.phase = phase
        }
    }

    func recursivelyPerformSteps(currentPhase: LLBCASFileTree.ImportPhase, currentPhaseSteps: [NextStep], nextPhaseSteps: [NextStep] = []) -> LLBFuture<[NextStep]> {
        let loop = self.loop
        var finishedSteps = [NextStep]()
        var waitInCurrentPhase = [LLBFuture<NextStep>]()
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
            case let .execute(in: phase, run) where phase <= currentPhase:
                waitInCurrentPhase.append(run())
            case let .wait(in: phase, futures) where phase <= currentPhase:
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
                let nextPhase = LLBCASFileTree.ImportPhase(rawValue: currentPhase.rawValue + 1)!
                guard nextPhase < .UploadingDirs else {
                    return loop.makeSucceededFuture(finishedSteps + nextPhaseSteps)
                }
                self.set(phase: nextPhase)
                return self.recursivelyPerformSteps(currentPhase: nextPhase, currentPhaseSteps: nextPhaseSteps).map {
                    finishedSteps + $0
                }
            } else {
                return self.recursivelyPerformSteps(currentPhase: currentPhase, currentPhaseSteps: moreStepsInCurrentPhase, nextPhaseSteps: nextPhaseSteps).map {
                    finishedSteps + $0
                }
            }
          }
    }

    struct SingleFileInfo {
        let path: AbsolutePath
        let id: LLBDataID
        let type: LLBFileType
        let size: UInt64
    }

    struct AnnotatedSegment {
        let isCompressed: Bool
        let uncompressedSize: Int
        let data: LLBFastData
    }

    struct SegmentDescriptor {
        let isCompressed: Bool
        let uncompressedSize: Int
        let id: LLBFuture<LLBDataID>

        init(isCompressed: Bool, uncompressedSize: Int, id: LLBFuture<LLBDataID>) {
            self.isCompressed = isCompressed
            self.uncompressedSize = uncompressedSize
            self.id = id
        }

        init(of segment: AnnotatedSegment, id: LLBFuture<LLBDataID>) {
            self.isCompressed = segment.isCompressed
            self.uncompressedSize = segment.uncompressedSize
            self.id = id
        }
    }

    /// Compress segments. If some segments are not compressible, the rest
    /// of the sequence won't be compressed either.
    func maybeCompressSegments(_ segmentsIn: [LLBFastData], allocator: LLBByteBufferAllocator) -> [AnnotatedSegment] {
        var useCompression = true
        return segmentsIn.map { segment in
            guard useCompression, let compressedSegment = try? segment.compressed(allocator: allocator) else {
                useCompression = false
                return AnnotatedSegment(isCompressed: false, uncompressedSize: segment.count, data: segment)
            }
            return AnnotatedSegment(isCompressed: true, uncompressedSize: segment.count, data: compressedSegment)
        }
    }

    indirect enum NextStep {
    // Final step in a sequence: stop stepping through.
    case skipped
    // Final step: information about the file.
    case singleFile(SingleFileInfo)
    // Final step: information about the directory.
    case gotDirectory(path: AbsolutePath)
    // Intermediate step: not earlier than in the given phase.
    case execute(in: LLBCASFileTree.ImportPhase, run: () -> LLBFuture<NextStep>)
    // This future has to be picked up in the given phase.
    case wait(in: LLBCASFileTree.ImportPhase, futures: [LLBFuture<NextStep>])
    // Intermediate result.
    case partialFileChunk(LLBDataID)
    }

    func describeAllSegments(of file: FileSegmenter) throws -> [SegmentDescriptor] {
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
            if case .compressed = options.wireFormat, file.size > 1024, !file.path.looksLikeCompressed, options.compressBufferAllocator != nil {
                useCompression = true
            } else {
                useCompression = false
            }

            let segment: AnnotatedSegment
            if useCompression, let compressedSegment = try? data.compressed(allocator: options.compressBufferAllocator!) {
                segment = AnnotatedSegment(isCompressed: true, uncompressedSize: data.count, data: compressedSegment)
            } else {
                useCompression = false
                segment = AnnotatedSegment(isCompressed: false, uncompressedSize: data.count, data: data)
            }

            descriptions.append(.init(of: segment, id: _db.identify(refs: [], data: segment.data.toByteBuffer())))
            if isEOF {
                break
            }
        }
        assert(descriptions.reduce(0, { acc, d in acc + d.uncompressedSize }) == file.size)
        return descriptions
    }

    func prepareSingleSegment(of file: FileSegmenter, segmentNumber: Int, useCompression: Bool) throws -> LLBFastData {

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

    func makeNextStep(path: AbsolutePath, type pathObjectType: FilesystemObjectType) throws -> NextStep {
        let loop = self.loop
        let stats = self.stats

        let segmentDescriptors: [SegmentDescriptor]  // Information about segments of file, possibly after compression.
        let type: LLBFileType
        let allSegmentsUncompressedDataSize: Int
        enum ObjectToImport {
        case link(target: LLBFastData)
        case file(file: FileSegmenter)
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

            let target = LLBFastData(buf[..<count].map{ UInt8($0) })
            allSegmentsUncompressedDataSize = target.count
            importObject = .link(target: target)
            segmentDescriptors = [SegmentDescriptor(isCompressed: false, uncompressedSize: target.count, id: _db.identify(refs: [], data: target.toByteBuffer()))]
        case .DIR:
            // If this is a directory, defer its processing.
            return .gotDirectory(path: path)
        case .REG:
            let file: FileSegmenter
            do {
                file = try FileSegmenter(importPath: importPath, path, segmentSize: options.fileChunkSize, minMmapSize: options.minMmapSize, allowInconsistency: options.relaxConsistencyChecks)
            } catch {
                guard options.skipUnreadable else {
                    throw ImportError.unreadableFile(path)
                }
                return .skipped
            }

            type = (file.statInfo.st_mode & 0o111 == 0) ? .plainFile : .executable
            importObject = .file(file: file)
            segmentDescriptors = try describeAllSegments(of: file)
            allSegmentsUncompressedDataSize = segmentDescriptors.reduce(0) {
                $0 + $1.uncompressedSize
            }
        default:
            return .skipped
        }

        // Add the rest of the chunks to the number of objects to import.
        _ = stats.toImportObjects_.add(max(0, allSegmentsUncompressedDataSize - 1) / options.fileChunkSize)
        _ = stats.toImportBytes_.add(allSegmentsUncompressedDataSize)
        _ = stats.toImportFiles_.add(1)

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

        func assemblePartialNextSteps() -> [LLBFuture<NextStep>] {
          let cheapNextAndPartialStepFutures: [(nextStepFuture: LLBFuture<NextStep>, partialStepFuture: LLBFuture<NextStep>)] = segmentDescriptors.enumerated().map { (segmentOffset, segm) in

              // This partial step is a final step for the sequence
              // of cheap/heavy steps, for a single segment (chunk).
              // We use cancellable promise since our heavy next steps might
              // not even run at all.
              let partialStepPromise = LLBCancellablePromise(promise: loop.makePromise(of: NextStep.self))

              func encodeNextStep(for id: LLBDataID) -> NextStep {
                if isSingleChunk {
                    return .singleFile(SingleFileInfo(path: path, id: id, type: type, size: UInt64(clamping: segm.uncompressedSize)))
                } else {
                    return .partialFileChunk(id)
                }
              }

              // If the file has non-standard layout, upload it after we upload
              // the binary blob.
              func uploadFileInfo(blobId: LLBDataID, importSize: Int? = nil) -> LLBFuture<NextStep> {
                guard finalResultPromise.isCompleted == false else {
                    return loop.makeSucceededFuture(NextStep.skipped)
                }

                // We need to wrap the blob in a `FileInformation`:
                // — When we compress the file.
                // — When the file is top level (importing a single file).
                guard segm.isCompressed || topLevel else {
                    if let size = importSize {
                        _ = stats.importedObjects_.add(1)
                        _ = stats.importedBytes_.add(size)
                    }
                    return loop.makeSucceededFuture(encodeNextStep(for: blobId))
                }

                var fileInfo = LLBFileInfo()
                // Each segment (if not a single segment) is encoded as a plain
                // file and doesn't have any other metadata (e.g. permissions).
                if isSingleChunk {
                    fileInfo.type = type
                } else {
                    fileInfo.type = .plainFile
                }
                fileInfo.size = UInt64(segm.uncompressedSize)
                fileInfo.compression = segm.isCompressed ? .zstd : .none
                fileInfo.fixedChunkSize = UInt64(segm.uncompressedSize)
                do {
                    return dbPut(refs: [blobId], data: try fileInfo.toBytes(), importSize: importSize).map { id in
                        encodeNextStep(for: id)
                    }
                } catch {
                    return loop.makeFailedFuture(error)
                }
              }

              let containsRequestWireSizeEstimate = 64

              let throttledContainsFuture = self.execute(on: self.netQueue, size: containsRequestWireSizeEstimate, default: .skipped) { () -> LLBFuture<NextStep> in
                let containsFuture = self.dbContains(segm)
                let containsLoop = containsFuture.eventLoop
                return containsFuture.flatMap { exists -> LLBFuture<NextStep> in

                  guard !exists else {
                    let existingIdFuture: LLBFuture<NextStep> = segm.id.flatMap { id in
                        return uploadFileInfo(blobId: id, importSize: segm.uncompressedSize)
                    }
                    existingIdFuture.cascade(to: partialStepPromise)
                    return existingIdFuture
                  }

                  return containsLoop.makeSucceededFuture(NextStep.execute(in: .UploadingFiles, run: {
                    let nextStepFuture: LLBFuture<NextStep> = self.execute(on: self.cpuQueue, default: nil) { () -> LLBFuture<NextStep>? in
                        let data: LLBFastData

                        switch importObject {
                        case let .link(target):
                            data = target
                        case let .file(file):
                            data = try self.prepareSingleSegment(of: file, segmentNumber: segmentOffset, useCompression: segm.isCompressed)
                        }

                        let slice = data.toByteBuffer()

                        // Make sure we want until the netQueue is sufficiently
                        // free to take our load. This ensures that we're not
                        // limited by CPU parallelism for network concurrency.
                        return self.executeWithBackpressure(on: self.netQueue, loop: containsLoop, size: slice.readableBytes, default: .skipped) { () -> LLBFuture<NextStep> in
                            return self.dbPut(refs: [], data: slice, importSize: segm.uncompressedSize).flatMap { id -> LLBFuture<NextStep> in
                                withExtendedLifetime(importObject) { // for mmap
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

              return (nextStepFuture: throttledContainsFuture, partialStepFuture: partialStepPromise.futureResult)
          }

          let cheapNextStepFutures: [LLBFuture<NextStep>] = cheapNextAndPartialStepFutures.map { $0.nextStepFuture }

          // Sending a single segment, for which we don't need
          // to wait until all of its subcomponents are uploaded.
          guard isSingleChunk == false else {
            return cheapNextStepFutures
          }

          let partialStepFutures = cheapNextAndPartialStepFutures.map { $0.partialStepFuture }
          let combinePartialResultsStep: NextStep = NextStep.execute(in: .UploadingWait, run: {
            return self.whenAllSucceed(partialStepFutures).flatMapErrorThrowing { error -> [NextStep] in
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
                }

                throw error

              }.flatMap { nextSteps in
                // The next steps can only be empty if we've reacting on
                // a filesystem-related error with some of our chunks.
                guard nextSteps.isEmpty == false else {
                    return loop.makeSucceededFuture(.skipped)
                }

                let chunkIds: [LLBDataID] = nextSteps.map {
                    guard case let .partialFileChunk(id) = $0 else {
                        preconditionFailure("Next step is not a partial chunk")
                    }
                    return id
                }

                var fileInfo = LLBFileInfo()
                fileInfo.type = type
                fileInfo.size = UInt64(allSegmentsUncompressedDataSize)
                // The top is not compressed when chunks are present.
                fileInfo.compression = .none
                fileInfo.fixedChunkSize = UInt64(chunkIds.count > 1 ? self.options.fileChunkSize : allSegmentsUncompressedDataSize)
                do {
                    let fileInfoBytes = try fileInfo.toBytes()
                    return self.execute(on: self.netQueue, size: fileInfoBytes.readableBytes, default: .skipped) {
                        self.dbPut(refs: chunkIds, data: fileInfoBytes, importSize: nil).map { id in
                            return .singleFile(SingleFileInfo(path: path, id: id, type: type, size: UInt64(clamping: allSegmentsUncompressedDataSize)))
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
        return .execute(in: .EstimatingSize, run: {
            loop.makeSucceededFuture(NextStep.wait(in: .CheckIfUploaded,
                futures: assemblePartialNextSteps()))
        })
    }

    /// Construct the bytes representing the directory contents.
        func constructDirectoryContents(_ subpaths: [(LLBDataID, LLBDirectoryEntry)?], wireFormat: LLBCASFileTree.WireFormat) throws -> (refs: [LLBDataID], dirData: LLBByteBuffer, aggregateSize: UInt64) {
        var refs = [LLBDataID]()
        let dirData: LLBByteBuffer
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

    private func whenAllSucceed<Value>(_ futures: [LLBFuture<Value>], on loop: LLBFuturesDispatchLoop? = nil) -> LLBFuture<[Value]> {
        let loop = loop ?? self.loop
        guard finalResultPromise.isCompleted == false else {
            return loop.makeSucceededFuture([])
        }
        return LLBFuture.whenAllSucceed(futures, on: loop).map { result in
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
    private func execute<T>(on queue: LLBBatchingFutureOperationQueue, default stopValue: T, _ body: @escaping () throws -> T) -> LLBFuture<T> {
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
    private func execute<T>(on queue: LLBFutureOperationQueue, loop: EventLoop? = nil, size: Int = 1, default stopValue: T, _ body: @escaping () -> LLBFuture<T>) -> LLBFuture<T> {
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
    private func executeWithBackpressure<T>(on queue: LLBFutureOperationQueue, loop: LLBFuturesDispatchLoop, size: Int = 1, default stopValue: T, _ body: @escaping () -> LLBFuture<T>) -> LLBFuture<T> {
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
    func compressed(allocator: LLBByteBufferAllocator) throws -> LLBFastData {
        let priorSize = count

        // Tolerate up to 1% overhead of non-compressible data.
        // If the overhead is larger, we'll assert in a debug mode.
        // This should prompt to reconsider the overhead value.
        let overhead = priorSize / 100 + 20
        var compressed = allocator.buffer(capacity: priorSize + overhead)

        let zstd = ZSTDStream()
        try zstd.startCompression(compressionLevel: 2)
        _ = try withContiguousStorage { ptr in
            try zstd.compress(input: UnsafeRawBufferPointer(ptr), andFinalize: true, into: &compressed)
        }

        assert(compressed.readableBytes <= priorSize + overhead, "Resize of the initial capacity estimate had just happened \(priorSize)+\(overhead)=\(priorSize+overhead) => \(compressed.readableBytes)")
        return LLBFastData(compressed)
    }
}

extension LLBFastData {
    internal func toByteBuffer() -> LLBByteBuffer {
        switch self {
        case let .view(data):
            return data
        case .slice, .data, .pointer:
            var buffer = LLBByteBufferAllocator().buffer(capacity: count)
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
