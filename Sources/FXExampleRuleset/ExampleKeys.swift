// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import llbuild2fx
import NIOCore

// MARK: - GreetingEntrypoint

public struct GreetingEntrypoint: FXEntrypoint, AsyncFXKey, Sendable {
    public typealias ValueType = GreetingValue

    public static let version = 1
    public static let versionDependencies: [FXVersioning.Type] = [FormatGreetingKey.self]
    public static let actionDependencies: [any FXAction.Type] = []
    public static let configurationKeys: [ConfigurationKey] = [.literal("greeting_style")]

    public let name: String

    public init(name: String) {
        self.name = name
    }

    public init(withEntrypointPayload casObject: FXCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let payload = try FXDecoder().decode(EntrypointPayload.self, from: data)
        self.name = payload.name
    }

    public init(withEntrypointPayload buffer: FXByteBuffer) throws {
        let data = Data(buffer.readableBytesView)
        let payload = try FXDecoder().decode(EntrypointPayload.self, from: data)
        self.name = payload.name
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
        let config = getConfigurationInputs(ctx)
        let style: String = config.get("greeting_style") ?? "casual"

        let formatKey = FormatGreetingKey(name: name, style: style)
        return try await fi.request(formatKey, ctx)
    }
}

private struct EntrypointPayload: Codable {
    let name: String
}

// MARK: - FormatGreetingKey

public struct FormatGreetingKey: AsyncFXKey, Sendable {
    public typealias ValueType = GreetingValue

    public static let version = 1
    public static let versionDependencies: [FXVersioning.Type] = [LookupPrefixKey.self]
    public static let actionDependencies: [any FXAction.Type] = [UppercaseAction.self]

    public let name: String
    public let style: String

    public init(name: String, style: String) {
        self.name = name
        self.style = style
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
        let greeting: String
        if style == "formal" {
            let prefixValue = try await fi.request(LookupPrefixKey(), ctx)
            greeting = "\(prefixValue.greeting) \(name), welcome!"
        } else {
            greeting = "Hi, \(name)!"
        }

        let uppercased = try await fi.spawn(UppercaseAction(input: greeting), ctx)
        return GreetingValue(greeting: uppercased.text)
    }
}

// MARK: - LookupPrefixKey

public struct LookupPrefixKey: AsyncFXKey, Sendable {
    public typealias ValueType = GreetingValue

    public static let version = 1
    public static let versionDependencies: [FXVersioning.Type] = []
    public static let actionDependencies: [any FXAction.Type] = []
    public static let resourceEntitlements: [ResourceKey] = [.external("greeting_prefix")]

    public init() {}

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
        guard let resource: PrefixResource = fi.resource(.external("greeting_prefix")) else {
            return GreetingValue(greeting: "Dear")
        }
        return GreetingValue(greeting: resource.prefix)
    }
}
