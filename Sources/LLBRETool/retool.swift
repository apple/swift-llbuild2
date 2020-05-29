// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

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

    public init(_ options: Options) {
        self.options = options
    }

    /// Put the given file into the CAS database.
    public func casPut(file: AbsolutePath) throws {
        let db = try openFileBackedCASDatabase()
        let data = try localFileSystem.readFileContents(file)
        let bytes = LLBByteBuffer.withBytes(data.contents[...])

        let result = try db.put(refs: [], data: bytes).wait()
        print(result)
    }

    /// Get the contents of the given data id from CAS database.
    public func casGet(id: LLBDataID, to outputFile: AbsolutePath) throws {
        let db = try openFileBackedCASDatabase()
        let result = try db.get(id).wait()
        guard let data = result?.data else {
            throw StringError("No data in \(id)")
        }
        guard let bytes = data.getBytes(at: 0, length: data.readableBytes) else {
            return
        }

        try localFileSystem.writeFileContents(outputFile, bytes: ByteString(bytes))
    }

    /// Open the file-backed CAS database.
    func openFileBackedCASDatabase() throws -> LLBCASDatabase {
        let casURL = options.frontend
        // We only support file-backed database right now.
        guard casURL.scheme == "file" else {
            throw StringError("unsupported CAS url \(casURL)")
        }

        let casPath = try AbsolutePath(validating: casURL.path)

        return LLBFileBackedCASDatabase(group: group, path: casPath)
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
