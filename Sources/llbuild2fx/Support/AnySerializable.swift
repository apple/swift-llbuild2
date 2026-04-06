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

// MARK:- PolymorphicSerializable -

/// Types conforming to LLBPolymorphicSerializable are allowed to be serialized into
/// LLBAnySerializable. They need to be registered in order to be deserialized
/// at runtime without compile-time type information.
public protocol LLBPolymorphicSerializable: FXSerializable {
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

public protocol FXSerializableLookup {
    func lookupType(identifier: String) -> LLBPolymorphicSerializable.Type?
}

/// Container for mapping registered identifiers to their runtime types.
public class FXSerializableRegistry: FXSerializableLookup {
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
    public func deserialize<T>(registry: FXSerializableLookup) throws -> T {
        guard let serializableType = registry.lookupType(identifier: typeIdentifier) else {
            throw LLBAnySerializableError.unknownType(typeIdentifier)
        }

        // FIXME: this extra buffer copy is unfortunate
        let buffer = FXByteBuffer.withBytes(ArraySlice<UInt8>(serializedBytes))
        guard let deserialized = try serializableType.init(from: buffer) as? T else {
            throw LLBAnySerializableError.typeMismatch("\(typeIdentifier) not convertible to \(T.Type.self)")
        }

        return deserialized
    }
}


// MARK:- CASObjectRepresentable for any Serializable via AnySerializable

extension LLBAnySerializable: FXSerializable {}

extension LLBPolymorphicSerializable {
    init(from casObject: FXCASObject, registry: FXSerializableLookup) throws {
        let any = try LLBAnySerializable(from: casObject.data)
        guard let objType = registry.lookupType(identifier: any.typeIdentifier) else {
            throw LLBAnySerializableError.unknownType(any.typeIdentifier)
        }
        // FIXME: this extra buffer copy is unfortunate
        let buffer = FXByteBuffer.withBytes(ArraySlice<UInt8>(any.serializedBytes))
        self = try objType.init(from: buffer) as! Self
    }
}

extension FXCASObjectRepresentable where Self: LLBPolymorphicSerializable {
    public func asCASObject() throws -> FXCASObject {
        let any = try LLBAnySerializable(from: self)
        return FXCASObject(refs: [], data: try any.toBytes())
    }
}

extension FXCASObjectRepresentable where Self: FXSerializable {
    public func asCASObject() throws -> FXCASObject {
        return FXCASObject(refs: [], data: try self.toBytes())
    }
}
extension FXCASObjectConstructable where Self: FXSerializable {
    public init(from casObject: FXCASObject) throws {
        try self.init(from: casObject.data)
    }
}

extension LLBAnySerializable: FXCASObjectConstructable {
    public init(from casObject: FXCASObject) throws {
        self = try LLBAnySerializable.init(from: casObject.data)
    }
}
