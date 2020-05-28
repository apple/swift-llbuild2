// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import ArgumentParser
import GRPC
import TSCBasic

extension URL: ExpressibleByArgument {
    public init?(argument: String) {
        if let parsed = URL(string: argument) {
            self = parsed
        } else {
            return nil
        }
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
