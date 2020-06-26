// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIOConcurrencyHelpers
import TSCBasic
import TSCUtility

import LLBCAS
import LLBSupport


public enum LLBExportError: Error {
    /// The given id was referenced as a directory, but the object encoding didn't match expectations.
    case unexpectedDirectoryData(LLBDataID)

    /// The given id was referenced as a file, but the object encoding didn't match expectations.
    case unexpectedFileData(LLBDataID)

    /// The given id was referenced as a symlink, but the object encoding didn't match expectations.
    case unexpectedSymlinkData(LLBDataID)

    /// The given id was required, but is missing.
    case missingReference(LLBDataID)

    /// An unexpected error was thrown while communicating with the database.
    case unexpectedDatabaseError(Error)

    /// Formatting/protocol error.
    case formatError(reason: String)

    /// There was an error interacting with the filesystem.
    case ioError(Error)
}

public enum LLBExportIOError: Error {
    /// Export was unable to export the symbolic link to `path` (with the given `target`).
    case unableToSymlink(path: AbsolutePath, target: String)
    case unableSyscall(path: AbsolutePath, call: String, error: String)
    case fileTooLarge(path: AbsolutePath)
    case uncompressFailed(path: AbsolutePath)
}

public extension LLBCASFileTree {

    final class ExportProgressStats {
        /// Bytes moved over the wire
        internal let bytesDownloaded_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Bytes logically copied over
        internal let bytesExported_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Bytes that have to be copied
        internal let bytesToExport_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Files/directories that have been synced
        internal let objectsExported_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Files/directories that have to be copied
        internal let objectsToExport_ = UnsafeEmbeddedAtomic<Int>(value: 0)
        /// Concurrent downloads in progress
        internal let downloadsInProgressObjects_ = UnsafeEmbeddedAtomic<Int>(value: 0)

        public var bytesDownloaded: Int { bytesDownloaded_.load() }
        public var bytesExported: Int { bytesExported_.load() }
        public var bytesToExport: Int { bytesToExport_.load() }
        public var objectsExported: Int { objectsExported_.load() }
        public var objectsToExport: Int { objectsToExport_.load() }
        public var downloadsInProgressObjects: Int { downloadsInProgressObjects_.load() }

        deinit {
            bytesDownloaded_.destroy()
            bytesExported_.destroy()
            bytesToExport_.destroy()
            objectsExported_.destroy()
            objectsToExport_.destroy()
            downloadsInProgressObjects_.destroy()
        }

        public var debugDescription: String {
            return """
                {bytesDownloaded: \(bytesDownloaded), \
                bytesExported: \(bytesExported), \
                bytesToExport: \(bytesToExport), \
                objectsExported: \(objectsExported), \
                objectsToExport: \(objectsToExport), \
                downloadsInProgressObjects: \(downloadsInProgressObjects)}
                """
        }

        public init() { }
    }

    /// Export an entire filesystem subtree [to disk].
    ///
    /// - Parameters:
    ///   - id:             The ID of the tree to export.
    ///   - from:           The database to import the content into.
    ///   - to:             The path to write the content to.
    ///   - materializer:   How to save files [to disk].
    static func export(
        _ id: LLBDataID,
        from db: LLBCASDatabase,
        to exportPathPrefix: AbsolutePath,
        materializer: LLBFilesystemObjectMaterializer = LLBRealFilesystemMaterializer(),
        storageBatcher: LLBBatchingFutureOperationQueue? = nil,
        stats: ExportProgressStats? = nil,
        _ ctx: Context
    ) -> LLBFuture<Void> {
        let delegate = CASFileTreeWalkerDelegate(from: db, to: exportPathPrefix, materializer: materializer, storageBatcher: storageBatcher, stats: stats ?? .init())
        let walker = ConcurrentHierarchyWalker(group: db.group, delegate: delegate)
        _ = stats?.objectsToExport_.add(1)
        return walker.walk(.init(id: id, exportPath: exportPathPrefix, kindHint: nil), ctx)
    }
}


private final class CASFileTreeWalkerDelegate: RetrieveChildrenProtocol {
    let db: LLBCASDatabase
    let exportPathPrefix: AbsolutePath
    let materializer: LLBFilesystemObjectMaterializer
    let stats: LLBCASFileTree.ExportProgressStats
    let storageBatcher: LLBBatchingFutureOperationQueue?

    struct Item {
        let id: LLBDataID
        let exportPath: AbsolutePath
        let kindHint: AnnotatedCASTreeChunk.ItemKind?
    }

    let allocator = LLBByteBufferAllocator()

    init(from db: LLBCASDatabase, to exportPathPrefix: AbsolutePath, materializer: LLBFilesystemObjectMaterializer, storageBatcher: LLBBatchingFutureOperationQueue?, stats: LLBCASFileTree.ExportProgressStats) {
        self.db = db
        self.exportPathPrefix = exportPathPrefix
        self.materializer = materializer
        self.stats = stats
        self.storageBatcher = storageBatcher
    }

    /// Conformance to `RetrieveChildrenProtocol`.
    func children(of item: Item, _ ctx: Context) -> LLBFuture<[Item]> {

        _ = stats.downloadsInProgressObjects_.add(1)

        let casObjectFuture: LLBFuture<LLBCASObject> = db.get(item.id, ctx).flatMapThrowing { casObject in
            _ = self.stats.downloadsInProgressObjects_.add(-1)

            guard let casObject = casObject else {
                throw LLBExportError.missingReference(item.id)
            }

            _ = self.stats.bytesDownloaded_.add(casObject.data.readableBytes)

            return casObject
        }

        if let batcher = self.storageBatcher {
          return casObjectFuture.flatMap { casObject in
            // Unblock the current NIO thread.
            batcher.execute {
                try self.parseAndMaterialize(casObject, item).map {
                    Item(id: $0.id, exportPath: $0.path, kindHint: $0.kind)
                }
            }
          }
        } else {
          return casObjectFuture.flatMapThrowing { casObject in
            try self.parseAndMaterialize(casObject, item).map {
                Item(id: $0.id, exportPath: $0.path, kindHint: $0.kind)
            }
          }
        }
    }


    /// Parse (may include buffer management, uncompression, copying)
    /// and materialize (going to the file system). This may or may not
    /// be run on the NIO threads, so don't wait().
    private func parseAndMaterialize(_ casObject: LLBCASObject, _ item: Item) throws -> [AnnotatedCASTreeChunk] {
        let (fsObject, others) = try CASFileTreeParser(for: self.exportPathPrefix, allocator: allocator).parseCASObject(id: item.id, path: item.exportPath, casObject: casObject, kind: item.kindHint)

        // Save some statistics.
        if case .directory = fsObject.content {
            var aggregateSize: Int = 0

            for entry in others {
                let (newAggregate, overflow) = aggregateSize.addingReportingOverflow(Int(clamping: entry.kind.overestimatedSize))
                aggregateSize = newAggregate
                assert(!overflow)
            }

            _ = stats.objectsToExport_.add(others.count)

            // If we downloaded the top object to figure out how much
            // we need to download, add that top object's size to aggregate.
            if self.stats.bytesExported_.load() == 0 {
                aggregateSize += casObject.data.readableBytes
            }

            // Record the largest aggregate size (top level?)
            repeat {
                let old = stats.bytesToExport_.load()
                guard aggregateSize > old else { break }
                guard !self.stats.bytesToExport_.compareAndExchange(expected: old, desired: aggregateSize) else {
                    break
                }
            } while aggregateSize > stats.bytesToExport_.load()
        }

        do {
            try materializer.materialize(object: fsObject)
        } catch {
            throw LLBExportError.ioError(error)
        }
        _ = stats.bytesExported_.add(fsObject.accountedDataSize)
        _ = stats.objectsExported_.add(fsObject.accountedObjects)
        return others
    }
}
