// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import GRPC
import Foundation

public struct Options {
    // FIXME: We should also support specifying specific endpoints for individual services.
    /// The frontend URL for all services (CAS, Action Cache, Execution).
    public var frontend: URL

    /// Custom gRPC headers to send with each request.
    public var grpcHeaders: [GRPCHeader]

    public init(
        frontend: URL,
        grpcHeaders: [GRPCHeader] = []
    ) {
        self.frontend = frontend
        self.grpcHeaders = grpcHeaders
    }
}

public typealias GRPCHeader = (key: String, value: String)
