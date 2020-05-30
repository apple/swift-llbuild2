// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO
import llbuild2
import GRPC
import SwiftProtobuf
import BazelRemoteAPI
import Foundation
import TSCBasic
import LLBUtil

/// Frontend to the remote execution tool.
public final class RETool {

    /// The tool options.
    public let options: Options

    public let group = LLBMakeDefaultDispatchGroup()
    let threadPool: NIOThreadPool
    let fileIO: NonBlockingFileIO

    public init(_ options: Options) {
        self.options = options

        let threadPool = NIOThreadPool(numberOfThreads: 6)
        self.threadPool = threadPool
        threadPool.start()
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
    }

    deinit {
        try? group.syncShutdownGracefully()
        try? threadPool.syncShutdownGracefully()
    }

    /// Put the given file into the CAS database.
    public func casPut(file: AbsolutePath) -> LLBFuture<LLBDataID> {
        let handleAndRegion = fileIO.openFile(
            path: file.pathString, eventLoop: group.next()
        )

        let buffer: LLBFuture<LLBByteBuffer> = handleAndRegion.flatMap { (handle, region) in
            let allocator = ByteBufferAllocator()
            return self.fileIO.read(
                fileRegion: region,
                allocator: allocator,
                eventLoop: self.group.next()
            )
        }

        let dbFuture = openFileBackedCASDatabase()
        return dbFuture.and(buffer).flatMap { (db, buf) in
            db.put(refs: [], data: buf)
        }
    }

    /// Get the contents of the given data id from CAS database.
    public func casGet(
        id: LLBDataID,
        to outputFile: AbsolutePath
    ) -> LLBFuture<Void> {
        let object = openFileBackedCASDatabase().flatMap { db in
            db.get(id)
        }

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
            )
        }
    }

    /// Open the file-backed CAS database.
    func openFileBackedCASDatabase() -> LLBFuture<LLBCASDatabase> {
        do {
            let casURL = options.frontend
            // We only support file-backed database right now.
            guard casURL.scheme == "file" else {
                throw StringError("unsupported CAS url \(casURL)")
            }

            let casPath = try AbsolutePath(validating: casURL.path)
            let db = LLBFileBackedCASDatabase(
                group: group,
                threadPool: threadPool,
                fileIO: fileIO,
                path: casPath
            )
            return group.next().makeSucceededFuture(db)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    /// Create client connection using the input options.
    func makeClientConnection() -> ClientConnection {
        // FIXME: Avoid force-unwrapping here.
        let target = try! options.frontend.toConnectionTarget()

        let configuration = ClientConnection.Configuration(
            target: target,
            eventLoopGroup: group
        )
        return ClientConnection(configuration: configuration)
    }

    /// Get the server capabilities of the remote endpoint.
    public func getCapabilities(
        instanceName: String? = nil
    ) -> LLBFuture<ServerCapabilities> {
        let connection = makeClientConnection()
        let client = CapabilitiesClient(channel: connection)
        client.defaultCallOptions.customMetadata.add(contentsOf: options.grpcHeaders)

        let request: GetCapabilitiesRequest
        if let instanceName = instanceName {
            request = .with {
                $0.instanceName = instanceName
            }
        } else {
            request = GetCapabilitiesRequest()
        }

        return client.getCapabilities(request).response
    }
}

extension URL {
    func toConnectionTarget() throws -> ConnectionTarget {
        // FIXME: Support unix scheme?
        guard let host = self.host else {
            throw StringError("no host in url \(self)")
        }
        guard let port = self.port else {
            throw StringError("no port in url \(self)")
        }
        return .hostAndPort(host, port)
    }
}
