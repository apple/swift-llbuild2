// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import TSCBasic
import TSCLibc
import Foundation
import NIO

public final class LLBFileBackedCASDatabase: LLBCASDatabase {
    /// Prefix for files written to disk.
    enum FileNamePrefix: String {
        case refs = "refs."
        case data = "data."
    }

    /// The content root path.
    public let path: AbsolutePath

    /// Threads capable of running futures.
    public let group: LLBFuturesDispatchGroup

    let threadPool: NIOThreadPool
    let fileIO: NonBlockingFileIO

    public init(
        group: LLBFuturesDispatchGroup,
        threadPool: NIOThreadPool,
        fileIO: NonBlockingFileIO,
        path: AbsolutePath
    ) {
        self.threadPool = threadPool
        self.fileIO = fileIO
        self.group = group
        self.path = path
        try? localFileSystem.createDirectory(path, recursive: true)
    }

    private func fileName(for id: LLBDataID, prefix: FileNamePrefix) -> AbsolutePath {
        return path.appending(component: prefix.rawValue + id.debugDescription)
    }

    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        group.next().makeSucceededFuture(LLBCASFeatures(preservesIDs: true))
    }

    public func contains(_ id: LLBDataID) -> LLBFuture<Bool> {
        let refsFile = fileName(for: id, prefix: .refs)
        let dataFile = fileName(for: id, prefix: .data)
        let contains = localFileSystem.exists(refsFile) && localFileSystem.exists(dataFile)
        return group.next().makeSucceededFuture(contains)
    }

    func readFile(file: AbsolutePath) -> LLBFuture<ByteBuffer> {
        let handleAndRegion = fileIO.openFile(
            path: file.pathString, eventLoop: group.next()
        )

        let data: LLBFuture<LLBByteBuffer> = handleAndRegion.flatMap { (handle, region) in
            let allocator = ByteBufferAllocator()
            return self.fileIO.read(
                fileRegion: region,
                allocator: allocator,
                eventLoop: self.group.next()
            )
        }

        return handleAndRegion.and(data).flatMapThrowing { (handle, data) in
            try handle.0.close()
            return data
        }
    }

    public func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?> {
        let refsFile = fileName(for: id, prefix: .refs)
        let dataFile = fileName(for: id, prefix: .data)

        let refsBytes: LLBFuture<[UInt8]> = readFile(file: refsFile).map { refsData in
            if let bytes = refsData.getBytes(at: 0, length: refsData.readableBytes) {
                return bytes
            }
            return []
        }

        let refs = refsBytes.flatMapThrowing {
            try JSONDecoder().decode([LLBDataID].self, from: Data($0))
        }

        let data = readFile(file: dataFile)

        return refs.and(data).map {
            LLBCASObject(refs: $0.0, data: $0.1)
        }
    }

    var fs: FileSystem { localFileSystem }

    public func identify(
        refs: [LLBDataID] = [],
        data: LLBByteBuffer
    ) -> LLBFuture<LLBDataID> {
        return group.next().makeSucceededFuture(LLBDataID(blake3hash: data, refs: refs))
    }

    public func put(
        refs: [LLBDataID] = [],
        data: LLBByteBuffer
    ) -> LLBFuture<LLBDataID> {
        let id = LLBDataID(blake3hash: data, refs: refs)
        return put(knownID: id, refs: refs, data: data)
    }

    public func put(
        knownID id: LLBDataID,
        refs: [LLBDataID] = [],
        data: LLBByteBuffer
    ) -> LLBFuture<LLBDataID> {
        let dataFile = fileName(for: id, prefix: .data)
        let dataFuture = writeIfNeeded(data: data, path: dataFile)

        let refsFile = fileName(for: id, prefix: .refs)
        let refData = try! JSONEncoder().encode(refs)
        let refBytes = LLBByteBuffer.withBytes(ArraySlice<UInt8>(refData))
        let refFuture = writeIfNeeded(data: refBytes, path: refsFile)

        return dataFuture.and(refFuture).map { _ in id }
    }

    /// Write the given data to the path if the size of data
    /// differs from the size at path.
    private func writeIfNeeded(
        data: LLBByteBuffer,
        path: AbsolutePath
    ) -> LLBFuture<Void> {
        let handle = fileIO.openFile(
            path: path.pathString,
            mode: .write,
            flags: .allowFileCreation(),
            eventLoop: group.next()
        )

        let size = handle.flatMap { handle in
             self.fileIO.readFileSize(
                fileHandle: handle,
                eventLoop: self.group.next()
            )
        }

        let result = size.and(handle).flatMap { (size, handle) -> LLBFuture<Void> in
            if size == data.readableBytes {
                return self.group.next().makeSucceededFuture(())
            }

            return self.fileIO.write(
                fileHandle: handle,
                buffer: data,
                eventLoop: self.group.next()
            )
        }

        return handle.and(result).flatMapThrowing { (handle, _) in
            try handle.close()
        }
    }

}
