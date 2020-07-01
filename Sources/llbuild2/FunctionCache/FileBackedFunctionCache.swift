// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO
import NIOConcurrencyHelpers
import TSCBasic


/// A simple in-memory implementation of the `LLBFunctionCache` protocol.
public final class LLBFileBackedFunctionCache: LLBFunctionCache {
    /// The content root path.
    public let path: AbsolutePath

    /// Threads capable of running futures.
    public let group: LLBFuturesDispatchGroup

    let threadPool: NIOThreadPool
    let fileIO: NonBlockingFileIO

    /// Create an in-memory database.
    public init(group: LLBFuturesDispatchGroup, path: AbsolutePath, version: String = "default") {
        self.group = group
        self.threadPool = NIOThreadPool(numberOfThreads: 6)
        threadPool.start()
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
        self.path = path.appending(component: version)
        try? localFileSystem.createDirectory(self.path, recursive: true)
    }

    deinit {
        try? threadPool.syncShutdownGracefully()
    }

    private func filePath(key: LLBKey) -> AbsolutePath {
        return path.appending(component: "\(key.stableHashValue)")
    }

    public func get(key: LLBKey, _ ctx: Context) -> LLBFuture<LLBDataID?> {
        let file = filePath(key: key)
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
            return try LLBDataID(from: data)
        }.recover { _ in
            return nil
        }
    }

    public func update(key: LLBKey, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void> {
        let file = filePath(key: key)
        let handle = fileIO.openFile(
            path: file.pathString,
            mode: .write,
            flags: .allowFileCreation(),
            eventLoop: group.next()
        )

        let result = handle.flatMap { handle -> LLBFuture<Void> in
            do {
                return self.fileIO.write(
                    fileHandle: handle,
                    buffer: try value.toBytes(),
                    eventLoop: self.group.next()
                )
            } catch {
                return self.group.next().makeFailedFuture(error)
            }
        }

        return handle.and(result).flatMapThrowing { (handle, _) in
            try handle.close()
        }
    }
}
