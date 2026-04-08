// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import Atomics
import FXCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import TSCBasic
import TSCUtility

package enum LLBExportError: Error {
    /// The given id was referenced as a directory, but the object encoding didn't match expectations.
    case unexpectedDirectoryData(FXDataID)

    /// The given id was referenced as a file, but the object encoding didn't match expectations.
    case unexpectedFileData(FXDataID)

    /// The given id was referenced as a symlink, but the object encoding didn't match expectations.
    case unexpectedSymlinkData(FXDataID)

    /// The given id was required, but is missing.
    case missingReference(FXDataID)

    /// An unexpected error was thrown while communicating with the database.
    case unexpectedDatabaseError(Error)

    /// Formatting/protocol error.
    case formatError(reason: String)

    /// There was an error interacting with the filesystem.
    case ioError(Error)
}

package enum LLBExportIOError: Error {
    /// Export was unable to export the symbolic link to `path` (with the given `target`).
    case unableToSymlink(path: AbsolutePath, target: String)
    case unableSyscall(path: AbsolutePath, call: String, error: String)
    case fileTooLarge(path: AbsolutePath)
    case uncompressFailed(path: AbsolutePath)
}

@available(
    *, deprecated,
    message:
        "New clients should use FXCASFileTreeExportProgressStatsInt64 to prevent wrong stats due to overflow."
)
package protocol FXCASFileTreeExportProgressStats: AnyObject {
    var bytesDownloaded: Int { get }
    var bytesExported: Int { get }
    var bytesToExport: Int { get }
    var objectsExported: Int { get }
    var objectsToExport: Int { get }
    var downloadsInProgressObjects: Int { get }
    var debugDescription: String { get }
}

package protocol FXCASFileTreeExportProgressStatsInt64: AnyObject {
    var bytesDownloaded: Int64 { get }
    var bytesExported: Int64 { get }
    var bytesToExport: Int64 { get }
    var objectsExported: Int64 { get }
    var objectsToExport: Int64 { get }
    var downloadsInProgressObjects: Int64 { get }
    var debugDescription: String { get }
}

extension FXCASFileTree {

    package final class ExportProgressStatsInt64: FXCASFileTreeExportProgressStatsInt64 {
        /// Bytes moved over the wire
        internal let bytesDownloaded_ = ManagedAtomic<Int64>(0)
        /// Bytes logically copied over
        internal let bytesExported_ = ManagedAtomic<Int64>(0)
        /// Bytes that have to be copied
        internal let bytesToExport_ = ManagedAtomic<Int64>(0)
        /// Files/directories that have been synced
        internal let objectsExported_ = ManagedAtomic<Int64>(0)
        /// Files/directories that have to be copied
        internal let objectsToExport_ = ManagedAtomic<Int64>(0)
        /// Concurrent downloads in progress
        internal let downloadsInProgressObjects_ = ManagedAtomic<Int64>(0)

        package var bytesDownloaded: Int64 { bytesDownloaded_.load(ordering: .relaxed) }
        package var bytesExported: Int64 { bytesExported_.load(ordering: .relaxed) }
        package var bytesToExport: Int64 { bytesToExport_.load(ordering: .relaxed) }
        package var objectsExported: Int64 { objectsExported_.load(ordering: .relaxed) }
        package var objectsToExport: Int64 { objectsToExport_.load(ordering: .relaxed) }
        package var downloadsInProgressObjects: Int64 {
            downloadsInProgressObjects_.load(ordering: .relaxed)
        }

        package var debugDescription: String {
            return """
                {bytesDownloaded: \(bytesDownloaded), \
                bytesExported: \(bytesExported), \
                bytesToExport: \(bytesToExport), \
                objectsExported: \(objectsExported), \
                objectsToExport: \(objectsToExport), \
                downloadsInProgressObjects: \(downloadsInProgressObjects)}
                """
        }

        package init() {}
    }

    @available(
        *, deprecated,
        message:
            "New clients should use ExportProgressStatsInt64 to prevent wrong stats due to overflow."
    )
    package final class ExportProgressStats: FXCASFileTreeExportProgressStats {
        internal let exportProgressStatsInt64 = ExportProgressStatsInt64()

        package var bytesDownloaded: Int { Int(clamping: exportProgressStatsInt64.bytesDownloaded) }
        package var bytesExported: Int { Int(clamping: exportProgressStatsInt64.bytesExported) }
        package var bytesToExport: Int { Int(clamping: exportProgressStatsInt64.bytesToExport) }
        package var objectsExported: Int { Int(clamping: exportProgressStatsInt64.objectsExported) }
        package var objectsToExport: Int { Int(clamping: exportProgressStatsInt64.objectsToExport) }
        package var downloadsInProgressObjects: Int {
            Int(clamping: exportProgressStatsInt64.downloadsInProgressObjects)
        }

        package var debugDescription: String {
            // Not using the description from ExportProgressStatsInt64, because there can be differences in the case of overflow and don't want inconsistencies between the debug description and the numbers we are reporting here. If clients want the right numbers in all cases, they should use ExportProgressStatsInt64.
            return """
                {bytesDownloaded: \(bytesDownloaded), \
                bytesExported: \(bytesExported), \
                bytesToExport: \(bytesToExport), \
                objectsExported: \(objectsExported), \
                objectsToExport: \(objectsToExport), \
                downloadsInProgressObjects: \(downloadsInProgressObjects)}
                """
        }

        package init() {}
    }

    /// Export an entire filesystem subtree [to disk].
    ///
    /// - Parameters:
    ///   - id:             The ID of the tree to export.
    ///   - from:           The database to import the content into.
    ///   - to:             The path to write the content to.
    ///   - materializer:   How to save files [to disk].
    @available(
        *, deprecated,
        message:
            "Please use export with the ExportProgressStatsInt64 stats to prevent wrong stats due to overflow."
    )
    package static func export(
        _ id: FXDataID,
        from db: any FXCASDatabase,
        to exportPathPrefix: AbsolutePath,
        materializer: LLBFilesystemObjectMaterializer = LLBRealFilesystemMaterializer(),
        storageBatcher: LLBBatchingFutureOperationQueue? = nil,
        stats: ExportProgressStats? = nil,
        _ ctx: Context
    ) -> FXFuture<Void> {
        export(
            id, from: db, to: exportPathPrefix, materializer: materializer,
            storageBatcher: storageBatcher, stats: stats?.exportProgressStatsInt64 ?? .init(), ctx)
    }

    /// Export an entire filesystem subtree [to disk].
    ///
    /// - Parameters:
    ///   - id:             The ID of the tree to export.
    ///   - from:           The database to import the content into.
    ///   - to:             The path to write the content to.
    ///   - materializer:   How to save files [to disk].
    package static func export(
        _ id: FXDataID,
        from db: any FXCASDatabase,
        to exportPathPrefix: AbsolutePath,
        materializer: LLBFilesystemObjectMaterializer = LLBRealFilesystemMaterializer(),
        storageBatcher: LLBBatchingFutureOperationQueue? = nil,
        stats: ExportProgressStatsInt64,
        _ ctx: Context
    ) -> FXFuture<Void> {
        let storageBatcher = storageBatcher ?? ctx.fileTreeExportStorageBatcher
        let stats = stats
        let delegate = CASFileTreeWalkerDelegate(
            from: db, to: exportPathPrefix, materializer: materializer,
            storageBatcher: storageBatcher, stats: stats)

        let walker = ConcurrentHierarchyWalker(group: db.group, delegate: delegate)
        stats.objectsToExport_.wrappingIncrement(ordering: .relaxed)
        return walker.walk(.init(id: id, exportPath: exportPathPrefix, kindHint: nil), ctx)
    }
}

private final class CASFileTreeWalkerDelegate: RetrieveChildrenProtocol {
    let db: any FXCASDatabase
    let exportPathPrefix: AbsolutePath
    let materializer: LLBFilesystemObjectMaterializer
    let stats: FXCASFileTree.ExportProgressStatsInt64
    let storageBatcher: LLBBatchingFutureOperationQueue?

    struct Item {
        let id: FXDataID
        let exportPath: AbsolutePath
        let kindHint: AnnotatedCASTreeChunk.ItemKind?
    }

    let allocator = FXByteBufferAllocator()

    init(
        from db: any FXCASDatabase, to exportPathPrefix: AbsolutePath,
        materializer: LLBFilesystemObjectMaterializer,
        storageBatcher: LLBBatchingFutureOperationQueue?,
        stats: FXCASFileTree.ExportProgressStatsInt64
    ) {
        self.db = db
        self.exportPathPrefix = exportPathPrefix
        self.materializer = materializer
        self.stats = stats
        self.storageBatcher = storageBatcher
    }

    /// Conformance to `RetrieveChildrenProtocol`.
    func children(of item: Item, _ ctx: Context) -> FXFuture<[Item]> {

        stats.downloadsInProgressObjects_.wrappingIncrement(ordering: .relaxed)

        let casObjectFuture: FXFuture<FXCASObject> = db.get(item.id, ctx).flatMapThrowing {
            casObject in
            self.stats.downloadsInProgressObjects_.wrappingDecrement(ordering: .relaxed)

            guard let casObject = casObject else {
                throw LLBExportError.missingReference(item.id)
            }

            self.stats.bytesDownloaded_.wrappingIncrement(
                by: Int64(casObject.data.readableBytes), ordering: .relaxed)

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
    private func parseAndMaterialize(_ casObject: FXCASObject, _ item: Item) throws
        -> [AnnotatedCASTreeChunk]
    {
        let (fsObject, others) = try CASFileTreeParser(
            for: self.exportPathPrefix, allocator: allocator
        ).parseCASObject(
            id: item.id, path: item.exportPath, casObject: casObject, kind: item.kindHint)

        // Save some statistics.
        if case .directory = fsObject.content {
            var aggregateSize: Int = 0

            for entry in others {
                let (newAggregate, overflow) = aggregateSize.addingReportingOverflow(
                    Int(clamping: entry.kind.overestimatedSize))
                aggregateSize = newAggregate
                assert(!overflow)
            }

            stats.objectsToExport_.wrappingIncrement(by: Int64(others.count), ordering: .relaxed)

            // If we downloaded the top object to figure out how much
            // we need to download, add that top object's size to aggregate.
            if self.stats.bytesExported_.load(ordering: .relaxed) == 0 {
                aggregateSize += casObject.data.readableBytes
            }

            // Record the largest aggregate size (top level?)
            repeat {
                let old = stats.bytesToExport_.load(ordering: .relaxed)
                guard aggregateSize > old else { break }
                guard
                    !self.stats.bytesToExport_.compareExchange(
                        expected: old, desired: Int64(aggregateSize),
                        ordering: .sequentiallyConsistent
                    ).0
                else {
                    break
                }
            } while aggregateSize > stats.bytesToExport_.load(ordering: .relaxed)
        }

        do {
            try materializer.materialize(object: fsObject)
        } catch {
            throw LLBExportError.ioError(error)
        }
        stats.bytesExported_.wrappingIncrement(
            by: Int64(fsObject.accountedDataSize), ordering: .relaxed)
        stats.objectsExported_.wrappingIncrement(
            by: Int64(fsObject.accountedObjects), ordering: .relaxed)
        return others
    }
}
