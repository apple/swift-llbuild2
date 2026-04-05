// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSFFutures

// MARK: - GreetingEntrypoint

package struct GreetingEntrypoint: FXEntrypoint, AsyncFXKey, Sendable {
    package typealias ValueType = GreetingValue

    package static let version = 1
    package static let versionDependencies: [FXVersioning.Type] = [FormatGreetingKey.self]
    package static let actionDependencies: [any FXAction.Type] = []
    package static let configurationKeys: [ConfigurationKey] = [.literal("greeting_style")]

    package let name: String

    package init(name: String) {
        self.name = name
    }

    package init(withEntrypointPayload casObject: LLBCASObject) throws {
        let data = Data(casObject.data.readableBytesView)
        let payload = try FXDecoder().decode(EntrypointPayload.self, from: data)
        self.name = payload.name
    }

    package init(withEntrypointPayload buffer: LLBByteBuffer) throws {
        let data = Data(buffer.readableBytesView)
        let payload = try FXDecoder().decode(EntrypointPayload.self, from: data)
        self.name = payload.name
    }

    package func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
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

package struct FormatGreetingKey: AsyncFXKey, Sendable {
    package typealias ValueType = GreetingValue

    package static let version = 1
    package static let versionDependencies: [FXVersioning.Type] = [LookupPrefixKey.self]
    package static let actionDependencies: [any FXAction.Type] = [UppercaseAction.self]

    package let name: String
    package let style: String

    package init(name: String, style: String) {
        self.name = name
        self.style = style
    }

    package func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
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

package struct LookupPrefixKey: AsyncFXKey, Sendable {
    package typealias ValueType = GreetingValue

    package static let version = 1
    package static let versionDependencies: [FXVersioning.Type] = []
    package static let actionDependencies: [any FXAction.Type] = []
    package static let resourceEntitlements: [ResourceKey] = [.external("greeting_prefix")]

    package init() {}

    package func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> GreetingValue {
        guard let resource: PrefixResource = fi.resource(.external("greeting_prefix")) else {
            return GreetingValue(greeting: "Dear")
        }
        return GreetingValue(greeting: resource.prefix)
    }
}
