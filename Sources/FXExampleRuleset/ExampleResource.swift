// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


import llbuild2fx
public final class PrefixResource: FXResource, @unchecked Sendable {
    public let name: String
    public let version: Int?
    public let lifetime: ResourceLifetime

    public var prefix: String

    public init(prefix: String = "Dear", version: Int = 1) {
        self.name = "greeting_prefix"
        self.version = version
        self.lifetime = .versioned
        self.prefix = prefix
    }
}
