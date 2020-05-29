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


/// A Bazel RE2 backed implementation of the `LLBCASDatabase` protocol.
public final class LLBBazelCASDatabase {
    /// Threads capable of running futures.
    public var group: LLBFuturesDispatchGroup

    private let client: ContentAddressableStorageClient
    private let instance: String?

    public enum Error: Swift.Error {
        case Unimplemented
    }

    /// Connect to a Bazel RE2 CAS database
    public init(group: LLBFuturesDispatchGroup, frontend: ConnectionTarget, instance: String? = nil) {
        self.group = group
        self.instance = instance

        let configuration = ClientConnection.Configuration(
            target: frontend,
            eventLoopGroup: group
        )
        let connection = ClientConnection(configuration: configuration)
        self.client = ContentAddressableStorageClient(channel: connection)
    }
}

extension LLBBazelCASDatabase: LLBCASDatabase {
    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        return group.next().makeSucceededFuture(LLBCASFeatures(preservesIDs: false))
    }

    public func contains(_ id: LLBDataID) -> LLBFuture<Bool> {
        var request: FindMissingBlobsRequest
        if let instance = instance {
            request = .with {
                $0.instanceName = instance
            }
        } else {
            request = FindMissingBlobsRequest()
        }
        request.blobDigests.append(id.asBazelDigest)

        return client.findMissingBlobs(request).response.map {
            return $0.missingBlobDigests.isEmpty
        }
    }

    public func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?> {
        return group.next().makeFailedFuture(Error.Unimplemented)
    }

    public func put(refs: [LLBDataID] = [], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        return group.next().makeFailedFuture(Error.Unimplemented)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID] = [], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        // Bazel DataIDs are intrinsically tied to the internal protobuf storage
        // While it is possible a client could have it already, we'd have to go
        // through the motions to confirm anyway.
        return put(refs: refs, data: data)
    }
}
