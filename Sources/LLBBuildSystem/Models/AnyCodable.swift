// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Dispatch
import Foundation

/// Types conforming to LLBPolymorphicCodable are allowed to be serialized into LLBAnySerializable. They need to be
/// registered in order to be deserialized at runtime without compile-time type information.
public protocol LLBPolymorphicCodable: LLBSerializable {
    static var polymorphicIdentifier: String { get }
}

/// Make all LLBCodables automatically conform to this by retrieving it's described type. This is not ideal since it
/// doesn't return the module name. Later on, we might be able to migrate this logic to use _mangledTypeName instead to
/// make this more robust.
extension LLBPolymorphicCodable {
    public static var polymorphicIdentifier: String {
        return String(describing: Self.self)
    }
}

/// Private serial queue for registeredType modifications.
fileprivate let queue = DispatchQueue(label: "org.swift.llbuild2.anycodable")

/// Types registered at runtime that are allowed to be deserialized.
fileprivate var registeredTypes: [String: LLBPolymorphicCodable.Type] = [:]

// Convenience internal initializer.
extension LLBAnySerializable {
    internal init(from polymorphicCodable: LLBPolymorphicCodable) throws {
        self.typeIdentifier = type(of: polymorphicCodable).polymorphicIdentifier
        self.serializedBytes = try Data(polymorphicCodable.toBytes().readableBytesView)
    }
}

// API for registering and retrieving registered types into the global registry. These methods are internal for now so
// that the API surface for what is allowed to be registered is controlled. If we find use cases where making this
// public would help, we might reconsider this.
extension LLBAnySerializable {
    internal static func register(type: LLBPolymorphicCodable.Type) {
        queue.sync {
            if registeredTypes[type.polymorphicIdentifier] == nil {
                registeredTypes[type.polymorphicIdentifier] = type
            }
        }
    }

    /// Returns the registered type for this LLBAnySerializable, or nil if it wasn't registered.
    internal func registeredType() -> LLBPolymorphicCodable.Type? {
        return registeredTypes[typeIdentifier]
    }
}
