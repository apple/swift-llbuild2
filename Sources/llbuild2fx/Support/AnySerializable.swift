// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOConcurrencyHelpers
import SwiftProtobuf
import TSFUtility

// MARK:- PolymorphicSerializable -

/// Types conforming to LLBPolymorphicSerializable are allowed to be serialized into
/// LLBAnySerializable. They need to be registered in order to be deserialized
/// at runtime without compile-time type information.
public protocol LLBPolymorphicSerializable: LLBSerializable {
    static var polymorphicIdentifier: String { get }
}

/// Make all LLBSerializbles automatically conform to this by retrieving it's
/// described type. This is not ideal since it doesn't return the module name.
/// Later on, we might be able to migrate this logic to use _mangledTypeName
/// instead to make this more robust.
extension LLBPolymorphicSerializable {
    public static var polymorphicIdentifier: String {
        return String(describing: Self.self)
    }
}

// Convenience internal initializer.
extension LLBAnySerializable {
    public init(from polymorphicSerializable: LLBPolymorphicSerializable) throws {
        self.typeIdentifier = type(of: polymorphicSerializable).polymorphicIdentifier
        self.serializedBytes = try Data(polymorphicSerializable.toBytes().readableBytesView)
    }
}


// MARK:- SerializableRegistry -

public protocol LLBSerializableLookup {
    func lookupType(identifier: String) -> LLBPolymorphicSerializable.Type?
}

/// Container for mapping registered identifiers to their runtime types.
public class LLBSerializableRegistry: LLBSerializableLookup {
    /// Types registered at runtime that are allowed to be deserialized.
    private var registeredTypes: [String: LLBPolymorphicSerializable.Type] = [:]

    public init() {}

    /// Register a new type for use in polymorphic serialization
    ///
    /// If a type has already been registered for this identifier, no change is
    /// made.
    ///
    /// CONCURRENCY: *NOT* Thread-safe
    public func register(type: LLBPolymorphicSerializable.Type) {
        if registeredTypes[type.polymorphicIdentifier] == nil {
            registeredTypes[type.polymorphicIdentifier] = type
        }
    }

    /// Lookup the register runtime type for a given type identifier
    public func lookupType(identifier: String) -> LLBPolymorphicSerializable.Type? {
        return registeredTypes[identifier]
    }
}


// MARK:- AnySerializable deserialization support -

public enum LLBAnySerializableError: Swift.Error {
    case unknownType(String)
    case typeMismatch(String)
}

extension LLBAnySerializable {
    public func deserialize<T>(registry: LLBSerializableLookup) throws -> T {
        guard let serializableType = registry.lookupType(identifier: typeIdentifier) else {
            throw LLBAnySerializableError.unknownType(typeIdentifier)
        }

        // FIXME: this extra buffer copy is unfortunate
        let buffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(serializedBytes))
        guard let deserialized = try serializableType.init(from: buffer) as? T else {
            throw LLBAnySerializableError.typeMismatch("\(typeIdentifier) not convertible to \(T.Type.self)")
        }

        return deserialized
    }
}


// MARK:- CASObjectRepresentable for any Serializable via AnySerializable

extension LLBAnySerializable: LLBSerializable {}

extension LLBPolymorphicSerializable {
    init(from casObject: LLBCASObject, registry: LLBSerializableLookup) throws {
        let any = try LLBAnySerializable(from: casObject.data)
        guard let objType = registry.lookupType(identifier: any.typeIdentifier) else {
            throw LLBAnySerializableError.unknownType(any.typeIdentifier)
        }
        // FIXME: this extra buffer copy is unfortunate
        let buffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(any.serializedBytes))
        self = try objType.init(from: buffer) as! Self
    }
}

extension LLBCASObjectRepresentable where Self: LLBPolymorphicSerializable {
    public func asCASObject() throws -> LLBCASObject {
        let any = try LLBAnySerializable(from: self)
        return LLBCASObject(refs: [], data: try any.toBytes())
    }
}

extension LLBCASObjectRepresentable where Self: LLBSerializable {
    public func asCASObject() throws -> LLBCASObject {
        return LLBCASObject(refs: [], data: try self.toBytes())
    }
}
extension LLBCASObjectConstructable where Self: LLBSerializable {
    public init(from casObject: LLBCASObject) throws {
        try self.init(from: casObject.data)
    }
}

extension LLBAnySerializable: LLBCASObjectConstructable {
    public init(from casObject: LLBCASObject) throws {
        self = try LLBAnySerializable.init(from: casObject.data)
    }
}
