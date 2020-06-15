// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import LLBSupport


/// A scheme for specifying a CASDatabase.
public protocol LLBCASDatabaseScheme {
    /// The name of the scheme.
    static var scheme: String { get }

    /// Check if a URL is valid for this scheme.
    static func isValid(host: String?, port: Int?, path: String, query: String?) -> Bool

    /// Open a content store in this scheme.
    static func open(group: LLBFuturesDispatchGroup, url: URL) throws -> LLBCASDatabase
}


/// A specification for a CAS database location.
///
/// Specifications are written using a URL scheme, for example:
///
///     mem://
public struct LLBCASDatabaseSpec {
    /// The map of registered schemes.
    private static var registeredSchemes: [String: LLBCASDatabaseScheme.Type] = [
        "mem": LLBInMemoryCASDatabaseScheme.self,
        "file": LLBFileBackedCASDatabaseScheme.self,
    ]

    /// Register a content store scheme type.
    ///
    /// This method is *not* thread safe.
    public static func register(schemeType: LLBCASDatabaseScheme.Type) {
        precondition(registeredSchemes[schemeType.scheme] == nil)
        registeredSchemes[schemeType.scheme] = schemeType
    }

    /// The underlying URL.
    public let url: URL

    /// The scheme definition.
    public let schemeType: LLBCASDatabaseScheme.Type

    public enum Error: Swift.Error {
        case noScheme
        case urlError(String)
    }

    /// Create a new spec for the given URL string.
    public init(_ string: String) throws {
        guard let url = URL(string: string) else {
            throw Error.urlError("URL parse error for \(string) for a CAS Database")
        }
        try self.init(url)
    }

    /// Create a new spec for the given URL.
    public init(_ url: URL) throws {
        guard let scheme = url.scheme else {
            throw Error.noScheme
        }

        // If the scheme isn't known, this isn't a valid spec.
        guard let schemeType = LLBCASDatabaseSpec.registeredSchemes[scheme] else {
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
    public func open(group: LLBFuturesDispatchGroup) throws -> LLBCASDatabase {
        return try schemeType.open(group: group, url: url)
    }
}

extension LLBCASDatabaseSpec: Equatable {
    public static func ==(lhs: LLBCASDatabaseSpec, rhs: LLBCASDatabaseSpec) -> Bool {
        return lhs.url == rhs.url
    }
}
