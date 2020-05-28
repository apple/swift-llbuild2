// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import ArgumentParser
import Foundation
import LLBRETool
import TSCUtility

struct Options: ParsableArguments {
    @Option(help: "The gRPC endpoint of the Bazel RE2 server")
    var url: Foundation.URL

    @Option(help: "Custom gRPC headers to send with each request", transform: headerTransformer)
    var grpcHeader: [GRPCHeader]
}

let headerTransformer: (String) -> (key: String, value: String) = { arg in
    let (key, value) = arg.spm_split(around: "=")
    return (key, value ?? "")
}
