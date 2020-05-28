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

/// Frontend to the remote execution tool.
public final class RETool {

    /// The tool options.
    public let options: Options

    public let group = LLBMakeDefaultDispatchGroup()

    public init(_ options: Options) {
        self.options = options
    }

    /// Create client connection using the input options.
    func makeClientConnection() -> ClientConnection {
        let configuration = ClientConnection.Configuration(
            target: options.frontend,
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
