// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import llbuild2

import BazelRemoteAPI
import GRPC
import NIOCore
import SwiftProtobuf
import TSCBasic


/// A Bazel RE2 backed implementation of the `LLBCASDatabase` protocol.
public final class LLBBazelCASDatabase {
    /// Threads capable of running futures.
    public var group: LLBFuturesDispatchGroup

    private let connection: ClientConnection
    private let headers: [GRPCHeader]
    private let bytestreamClient: Google_Bytestream_ByteStreamClient
    private let bytestreamUUID = UUID()
    private let casClient: ContentAddressableStorageClient
    private let instance: String?

    public enum Error: Swift.Error {
        case callFailed(GRPCStatus)
        case unexpectedConnectionString(String)
        case badURL
        case incompleteWrite
    }

    private typealias GRPCHeader = (key: String, value: String)

    /// Connect to a Bazel RE2 CAS database
    public init(group: LLBFuturesDispatchGroup, url: URL) throws {
        assert(url.scheme == "bazel")

        self.group = group

        // Parse headers from the URL
        if let query = url.query {
            guard let items = LLBBazelCASDatabase.extractQueryItems(query) else {
                throw Error.unexpectedConnectionString(query)
            }
            headers = items
        } else {
            headers = []
        }

        // Extract instance from the URL
        self.instance = url.path.isEmpty ? nil : String(url.path.dropFirst())


        // Cleanup the URL for GRPC connection
        guard let frontend = URL(string: "grpc://\(url.host ?? "localhost"):\(url.port ?? 8980)") else {
            throw Error.badURL
        }

        // Create the GRPC connection
        let configuration = ClientConnection.Configuration.default(
            target: try frontend.toConnectionTarget(),
            eventLoopGroup: group
        )
        self.connection = ClientConnection(configuration: configuration)
        self.bytestreamClient = Google_Bytestream_ByteStreamClient(channel: connection)
        self.bytestreamClient.defaultCallOptions.customMetadata.add(contentsOf: headers)
        self.casClient = ContentAddressableStorageClient(channel: connection)
        self.casClient.defaultCallOptions.customMetadata.add(contentsOf: headers)
    }

    private static func extractQueryItems(_ query: String) -> [GRPCHeader]? {
        guard let components = NSURLComponents(string: "?" + query) else {
            return nil
        }
        guard let queryItems = components.queryItems else {
            return nil
        }
        var results: [GRPCHeader] = []
        for item in queryItems {
            guard let value = item.value else {
                // A query item missing a value is unexpected.
                return nil
            }
            results.append((item.name, value))
        }
        return results
    }

    public func serverCapabilities() -> LLBFuture<ServerCapabilities> {
        let request: GetCapabilitiesRequest
        if let instanceName = instance {
            request = .with {
                $0.instanceName = instanceName
            }
        } else {
            request = GetCapabilitiesRequest()
        }

        let client = CapabilitiesClient(channel: connection)
        client.defaultCallOptions.customMetadata.add(contentsOf: headers)

        return client.getCapabilities(request).response
    }
}

extension LLBBazelCASDatabase: LLBCASDatabase {
    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        return group.next().makeSucceededFuture(LLBCASFeatures(preservesIDs: false))
    }

    public func contains(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<Bool> {
        var request: FindMissingBlobsRequest
        if let instance = instance {
            request = .with {
                $0.instanceName = instance
            }
        } else {
            request = FindMissingBlobsRequest()
        }
        do {
            request.blobDigests.append(try id.asBazelDigest())

            return casClient.findMissingBlobs(request).response.map {
                return $0.missingBlobDigests.isEmpty
            }
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    public func get(_ id: LLBDataID, _ ctx: Context) -> LLBFuture<LLBCASObject?> {
        do {
            let resourcePrefix: String
            if let instance = instance {
                resourcePrefix = "\(instance)/"
            } else {
                resourcePrefix = ""
            }
            let digest = try id.asBazelDigest()
            let resource = "\(resourcePrefix)blobs/\(digest.hash)/\(digest.sizeBytes)"

            let request =  Google_Bytestream_ReadRequest.with {
                $0.resourceName = resource
                $0.readOffset = 0
            }

            var buffer = LLBByteBufferAllocator().buffer(capacity: Int(digest.sizeBytes))
            let call = bytestreamClient.read(request) { response in
                buffer.writeBytes(response.data)
            }
            return call.status.flatMapThrowing { status -> LLBCASObject? in
                guard status.code == .ok else {
                    return nil
                }

                return try LLBCASObject(from: buffer)
            }
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    public func identify(refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        do {
            let id = try Digest(with: data.readableBytesView).asDataID()
            return group.next().makeSucceededFuture(id)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    public func put(refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        do {
            let resourcePrefix: String
            if let instance = instance {
                resourcePrefix = "\(instance)/"
            } else {
                resourcePrefix = ""
            }

            let object = LLBCASObject(refs: refs, data: data)
            let objData = try object.toData()

            let digest = Digest(with: objData)
            let resource = "\(resourcePrefix)uploads/\(bytestreamUUID)/blobs/\(digest.hash)/\(digest.sizeBytes)"

            let request =  Google_Bytestream_WriteRequest.with {
                $0.resourceName = resource
                $0.writeOffset = 0
                $0.finishWrite = true
                $0.data = objData
            }

            let call = bytestreamClient.write()
            _ = call.sendMessage(request)
            _ = call.sendEnd()
            return call.response.flatMapThrowing { response in
                guard response.committedSize == objData.count else {
                    throw Error.incompleteWrite
                }

                return try digest.asDataID()
            }
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID] = [], data: LLBByteBuffer, _ ctx: Context) -> LLBFuture<LLBDataID> {
        // Bazel DataIDs are intrinsically tied to the internal protobuf storage
        // While it is possible a client could have it already, we'd have to go
        // through the motions to confirm anyway.
        return put(refs: refs, data: data, ctx)
    }
}

public struct LLBBazelCASDatabaseScheme: LLBCASDatabaseScheme {
    public static let scheme = "bazel"

    public static func isValid(host: String?, port: Int?, path: String, query: String?) -> Bool {
        return true
    }

    public static func open(group: LLBFuturesDispatchGroup, url: URL) throws -> LLBCASDatabase {
        return try LLBBazelCASDatabase(group: group, url: url)
    }
}

public func registerCASSchemes() {
    LLBCASDatabaseSpec.register(schemeType: LLBBazelCASDatabaseScheme.self)
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
