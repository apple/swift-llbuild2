// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIO
import GRPC
import SwiftProtobuf
import BazelRemoteAPI
import TSCBasic

import llbuild2
import LLBBazelBackend
import LLBUtil


/// Frontend to the remote execution tool.
public final class LLBCASTool {

    /// The tool options.
    public let options: LLBCASToolOptions

    public let group: LLBFuturesDispatchGroup
    private let db: LLBCASDatabase

    let threadPool: NIOThreadPool
    let fileIO: NonBlockingFileIO

    public enum Error: Swift.Error {
        case unsupported
    }

    public init(group: LLBFuturesDispatchGroup, _ options: LLBCASToolOptions) throws {
        self.group = group
        self.options = options

        self.db = try LLBCASDatabaseSpec(options.url).open(group: group)

        let threadPool = NIOThreadPool(numberOfThreads: 6)
        self.threadPool = threadPool
        threadPool.start()
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
    }

    deinit {
        try? threadPool.syncShutdownGracefully()
    }

    /// Put the given file into the CAS database.
    public func casPut(file: AbsolutePath, _ ctx: Context) -> LLBFuture<LLBDataID> {
        let handleAndRegion = fileIO.openFile(
            path: file.pathString, eventLoop: group.next()
        )

        let buffer: LLBFuture<LLBByteBuffer> = handleAndRegion.flatMap { (handle, region) in
            let allocator = ByteBufferAllocator()
            return self.fileIO.read(
                fileRegion: region,
                allocator: allocator,
                eventLoop: self.group.next()
            ).flatMapThrowing { buffer in
                try handle.close()
                return buffer
            }
        }

        return buffer.flatMap { buf in
            self.db.put(refs: [], data: buf, ctx)
        }
    }

    /// Get the contents of the given data id from CAS database.
    public func casGet(
        id: LLBDataID,
        to outputFile: AbsolutePath,
        _ ctx: Context
    ) -> LLBFuture<Void> {
        let object = db.get(id, ctx)

        let data: LLBFuture<LLBByteBuffer> = object.flatMapThrowing {
            guard let data = $0?.data else {
                throw StringError("No object in CAS with id \(id)")
            }
            return data
        }

        let handle = fileIO.openFile(
            path: outputFile.pathString,
            mode: .write,
            flags: .allowFileCreation(),
            eventLoop: group.next()
        )

        return handle.and(data).flatMap { (handle, data) in
            self.fileIO.write(
                fileHandle: handle,
                buffer: data,
                eventLoop: self.group.next()
            ).flatMapThrowing { _ in
                try handle.close()
            }
        }
    }


    /// Get the server capabilities of the remote endpoint.
    public func getCapabilities() -> LLBFuture<ServerCapabilities> {
        guard let bazelDB = self.db as? LLBBazelCASDatabase else {
            return group.next().makeFailedFuture(Error.unsupported)
        }

        return bazelDB.serverCapabilities()
    }
}

