// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Foundation
import NIOCore

/// A scheme for specifying a CASDatabase.
package protocol FXCASDatabaseScheme {
    /// The name of the scheme.
    static var scheme: String { get }

    /// Check if a URL is valid for this scheme.
    static func isValid(host: String?, port: Int?, path: String, query: String?) -> Bool

    /// Open a content store in this scheme.
    static func open(group: FXFuturesDispatchGroup, url: URL) throws -> any FXCASDatabase
}

/// A specification for a CAS database location.
///
/// Specifications are written using a URL scheme, for example:
///
///     mem://
package struct FXCASDatabaseSpec {
    /// The map of registered schemes.
    private static var registeredSchemes: [String: FXCASDatabaseScheme.Type] = [
        "mem": FXInMemoryCASDatabaseScheme.self,
    ]

    /// Register a content store scheme type.
    ///
    /// This method is *not* thread safe.
    package static func register(schemeType: FXCASDatabaseScheme.Type) {
        precondition(registeredSchemes[schemeType.scheme] == nil)
        registeredSchemes[schemeType.scheme] = schemeType
    }

    /// The underlying URL.
    package let url: URL

    /// The scheme definition.
    package let schemeType: FXCASDatabaseScheme.Type

    package enum Error: Swift.Error {
        case noScheme
        case urlError(String)
    }

    /// Create a new spec for the given URL string.
    package init(_ string: String) throws {
        guard let url = URL(string: string) else {
            throw Error.urlError("URL parse error for \(string) for a CAS Database")
        }
        try self.init(url)
    }

    /// Create a new spec for the given URL.
    package init(_ url: URL) throws {
        guard let scheme = url.scheme else {
            throw Error.noScheme
        }

        // If the scheme isn't known, this isn't a valid spec.
        guard let schemeType = FXCASDatabaseSpec.registeredSchemes[scheme] else {
            throw Error.urlError("Unknown URL scheme \"\(scheme)\" for a CAS Database at \(url)")
        }

        // Validate the URL with the scheme.
        if !schemeType.isValid(host: url.host, port: url.port, path: url.path, query: url.query) {
            throw Error.urlError("Invalid URL \(url) for a CAS Database")
        }

        self.url = url
        self.schemeType = schemeType
    }

    /// Open the specified store.
    package func open(group: FXFuturesDispatchGroup) throws -> any FXCASDatabase {
        return try schemeType.open(group: group, url: url)
    }
}

extension FXCASDatabaseSpec: Equatable {
    package static func == (lhs: FXCASDatabaseSpec, rhs: FXCASDatabaseSpec) -> Bool {
        return lhs.url == rhs.url
    }
}
