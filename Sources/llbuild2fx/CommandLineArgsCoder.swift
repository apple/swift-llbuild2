// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


import Foundation

/// Read from an command line arguments like array of strings into Codable-conforming struct
/// Dots and equal signs are not allowed in keys
public struct CommandLineArgsDecoder {
    public init() {}
    public func decode<T: Decodable>(from args: [String], as type: T.Type = T.self) throws -> T {
        var argsContent: [String: String] = [:]
        var key: String?
        var topLevelIndex = 0
        let appendKV = { (k: String, v: String) in
            if argsContent[k] != nil {
                argsContent[k + ".0"] = argsContent[k]!
                argsContent[k] = nil
                argsContent[k + ".1"] = v
            } else if argsContent[k + ".0"] != nil {
                var i = 2
                while true {
                    let newk = k + "." + String(i)
                    if argsContent[newk] == nil {
                        argsContent[newk] = v
                        break
                    } else {
                        i += 1
                    }
                }
            } else {
                argsContent[k] = v
            }
            key = nil
        }
        for arg in args {
            if arg.hasPrefix("--") {
                if let keyContent = key {
                    // boolean --key format
                    appendKV(keyContent, "true")
                }
                let fields = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2 {
                    // --key=value format
                    appendKV(String(fields[0].dropFirst(2)), String(fields[1]))
                } else {
                    // --key
                    key = String(fields[0].dropFirst(2))
                }
            } else {
                if let keyContent = key {
                    // "--key value" format
                    appendKV(keyContent, arg)
                } else {
                    // top level array
                    appendKV(String(topLevelIndex), arg)
                    topLevelIndex += 1
                }
            }
        }
        if let keyContent = key {
            appendKV(keyContent, "true")
        }
        let sd = StringsDecoder()
        return try sd.decode(T.self, from: argsContent)
    }
}

/// Convert from Codable-conforming struct to command line arguments like array of strings
/// Dots and equal signs are not allowed in keys
/// Classes/structures go in --property=value lines, dictionaries go in --key=value, arrays go in --index=value, nil values omitted.
/// Nested values increase the number of dot-separated fields in keys.
public struct CommandLineArgsEncoder {
    public init() {}
    public func encode<T: Encodable>(_ value: T) throws -> [String] {
        try StringsEncoder()
            .encode(value)
            .map({ "--\($0)=\($1)" })
            .sorted()
    }
}

/// Stores the actual strings file data during encoding.
private final class CodingData {
    private(set) var strings: [String: String] = [:]

    init(_ strings: [String: String] = [:]) {
        self.strings = strings
    }

    func encode(key codingKey: [CodingKey], value: String) {
        let key = codingKey.map { $0.stringValue }.joined(separator: ".")
        strings[key] = value
    }

    func decode(key codingKey: [CodingKey]) throws -> String {
        let key = codingKey.map { $0.stringValue }.joined(separator: ".")
        let valueOpt = strings[key]
        guard let value = valueOpt else {
            throw DecodingError.keyNotFound(
                codingKey.last!, DecodingError.Context(codingPath: codingKey, debugDescription: "no key found: \(key)"))
        }
        return value
    }

    func contains(key codingKey: [CodingKey]) -> Bool {
        let key = codingKey.map { $0.stringValue }.joined(separator: ".")
        let valueOpt = strings[key]
        return valueOpt != nil
    }

    func allKeys<K: CodingKey>(key codingKey: [CodingKey]) -> [K] {
        let key = codingKey.map { $0.stringValue }.joined(separator: ".") + "."
        let matchingKeys = strings.compactMap { (k, v) -> String? in
            guard k.starts(with: key) else {
                return nil
            }
            let rest = k.dropFirst(key.count)
            guard !rest.isEmpty && !rest.first!.isNumber && !rest.contains(".") else {
                return nil
            }
            return String(rest)
        }
        return matchingKeys.compactMap { K(stringValue: $0) }
    }

    func countUnkeyed(key codingKey: [CodingKey]) -> Int {
        let key = codingKey.map { $0.stringValue }.joined(separator: ".") + "."
        let matchingKeys = strings.compactMap { (k, v) -> Bool? in
            guard k.starts(with: key) else {
                return nil
            }
            let rest = k.dropFirst(key.count)
            guard !rest.isEmpty && rest.first!.isNumber && !rest.contains(".") else {
                return nil
            }
            return true
        }
        return matchingKeys.count
    }
}

public class StringsEncoder {
    /// Returns a strings file-encoded representation of the specified value.
    public func encode<T: Encodable>(_ value: T) throws -> [String: String] {
        let stringsEncoding = StringsEncoding()
        try value.encode(to: stringsEncoding)
        return stringsEncoding.data.strings
    }
}

private struct StringsEncoding: Encoder {

    fileprivate var data: CodingData

    init(to encodedData: CodingData = CodingData(), codingPath: [CodingKey] = []) {
        self.data = encodedData
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey]

    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = StringsKeyedEncoding<Key>(to: data, codingPath: codingPath)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let container = StringsUnkeyedEncoding(to: data, codingPath: codingPath)
        return container
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        let container = StringsSingleValueEncoding(to: data, codingPath: codingPath)
        return container
    }
}

private struct StringsKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {

    private let data: CodingData

    init(to data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        // Don't add nil fields
        // data.encode(key: codingPath + [key], value: "nil")
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        data.encode(key: codingPath + [key], value: String(describing: value))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let stringsEncoding = StringsEncoding(to: data, codingPath: codingPath + [key])
        try value.encode(to: stringsEncoding)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let container = StringsKeyedEncoding<NestedKey>(to: data, codingPath: codingPath + [key])
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let container = StringsUnkeyedEncoding(to: data, codingPath: codingPath + [key])
        return container
    }

    mutating func superEncoder() -> Encoder {
        let superKey = Key(stringValue: "super")!
        return superEncoder(forKey: superKey)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let stringsEncoding = StringsEncoding(to: data, codingPath: codingPath + [key])
        return stringsEncoding
    }
}

private struct StringsUnkeyedEncoding: UnkeyedEncodingContainer {

    private let data: CodingData

    init(to data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey]

    private(set) var count: Int = 0

    private mutating func nextIndexedKey() -> CodingKey {
        let nextCodingKey = IndexedCodingKey(intValue: count)!
        count += 1
        return nextCodingKey
    }

    private struct IndexedCodingKey: CodingKey {
        let intValue: Int?
        let stringValue: String

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(describing: intValue)
        }

        init?(stringValue: String) {
            return nil
        }
    }

    mutating func encodeNil() throws {
        // Don't add nil fields
        // data.encode(key: codingPath + [nextIndexedKey()], value: "nil")
    }

    mutating func encode(_ value: Bool) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: String) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: value)
    }

    mutating func encode(_ value: Double) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Float) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Int) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Int8) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Int16) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Int32) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: Int64) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: UInt) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: UInt8) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: UInt16) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: UInt32) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode(_ value: UInt64) throws {
        data.encode(key: codingPath + [nextIndexedKey()], value: String(describing: value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let stringsEncoding = StringsEncoding(to: data, codingPath: codingPath + [nextIndexedKey()])
        try value.encode(to: stringsEncoding)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let container = StringsKeyedEncoding<NestedKey>(to: data, codingPath: codingPath + [nextIndexedKey()])
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let container = StringsUnkeyedEncoding(to: data, codingPath: codingPath + [nextIndexedKey()])
        return container
    }

    mutating func superEncoder() -> Encoder {
        let stringsEncoding = StringsEncoding(to: data, codingPath: [nextIndexedKey()])
        return stringsEncoding
    }
}

private struct StringsSingleValueEncoding: SingleValueEncodingContainer {

    private let data: CodingData

    init(to data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey]

    mutating func encodeNil() throws {
        // Don't add nil fields
        // data.encode(key: codingPath, value: "nil")
    }

    mutating func encode(_ value: Bool) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: String) throws {
        data.encode(key: codingPath, value: value)
    }

    mutating func encode(_ value: Double) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Float) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Int) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Int8) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Int16) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Int32) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: Int64) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: UInt) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: UInt8) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: UInt16) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: UInt32) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode(_ value: UInt64) throws {
        data.encode(key: codingPath, value: String(describing: value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let stringsEncoding = StringsEncoding(to: data, codingPath: codingPath)
        try value.encode(to: stringsEncoding)
    }
}

public class StringsDecoder {
    /// Creates an instance of the specified value from a strings file-encoded representation.
    public func decode<T: Decodable>(_ type: T.Type, from strings: [String: String]) throws -> T {
        let stringsDecoding = StringsDecoding(from: strings)
        return try .init(from: stringsDecoding)
    }
}

private struct StringsDecoding: Decoder {

    fileprivate var data: CodingData

    init(from encodedData: [String: String]) {
        self.data = CodingData(encodedData)
    }

    init(from encodedData: CodingData, codingPath: [CodingKey] = []) {
        self.data = encodedData
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey] = []

    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let container = StringsKeyedDecoding<Key>(from: data, codingPath: codingPath)
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        let container = StringsUnkeyedDecoding(from: data, codingPath: codingPath)
        return container
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        let container = StringsSingleValueDecoding(from: data, codingPath: codingPath)
        return container
    }
}

private struct StringsKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    private let data: CodingData

    init(from data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
        self.allKeys = data.allKeys(key: codingPath)
    }

    var codingPath: [CodingKey]

    private(set) var allKeys: [Key]

    func contains(_ key: Key) -> Bool {
        return data.contains(key: codingPath + [key])
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        !data.contains(key: codingPath + [key])
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let value = try data.decode(key: codingPath + [key])
        guard value == "true" || value == "false" else {
            throw DecodingError.typeMismatch(
                Bool.Type.self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "invalid value")
            )
        }
        return value == "true"
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let value = try data.decode(key: codingPath + [key])
        return value
    }

    private func genericDecode<T: LosslessStringConvertible>(_ key: Key) throws -> T {
        let value = try data.decode(key: codingPath + [key])
        let convertedOpt = T(value)
        guard let converted = convertedOpt else {
            throw DecodingError.typeMismatch(
                T.Type.self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "invalid value"))
        }
        return converted
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try genericDecode(key)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try genericDecode(key)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try genericDecode(key)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try genericDecode(key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try genericDecode(key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try genericDecode(key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try genericDecode(key)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try genericDecode(key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try genericDecode(key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try genericDecode(key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try genericDecode(key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try genericDecode(key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let stringsDecoding = StringsDecoding(from: data, codingPath: codingPath + [key])
        return try .init(from: stringsDecoding)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let container = StringsKeyedDecoding<NestedKey>(from: data, codingPath: codingPath + [key])
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let container = StringsUnkeyedDecoding(from: data, codingPath: codingPath + [key])
        return container
    }

    func superDecoder() throws -> Decoder {
        let superKey = Key(stringValue: "super")!
        return try superDecoder(forKey: superKey)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let stringsDecoding = StringsDecoding(from: data, codingPath: codingPath + [key])
        return stringsDecoding
    }
}

private struct StringsUnkeyedDecoding: UnkeyedDecodingContainer {

    private let data: CodingData

    init(from data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
        self.count = data.countUnkeyed(key: codingPath)
    }

    var codingPath: [CodingKey] = []

    private(set) var count: Int?

    var isAtEnd: Bool {
        return currentIndex >= count!
    }

    var currentIndex: Int = 0

    private mutating func nextIndexedKey() -> CodingKey {  // TODO: Should be next?
        let nextCodingKey = IndexedCodingKey(intValue: currentIndex)!
        currentIndex += 1
        return nextCodingKey
    }

    private struct IndexedCodingKey: CodingKey {
        let intValue: Int?
        let stringValue: String

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(describing: intValue)
        }

        init?(stringValue: String) {
            return nil
        }
    }

    mutating func decodeNil() throws -> Bool {
        !data.contains(key: codingPath + [nextIndexedKey()])
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let value = try data.decode(key: codingPath + [nextIndexedKey()])
        guard value == "true" || value == "false" else {
            throw DecodingError.typeMismatch(
                Bool.Type.self,
                DecodingError.Context(codingPath: codingPath + [nextIndexedKey()], debugDescription: "invalid value"))
        }
        return value == "true"
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let value = try data.decode(key: codingPath + [nextIndexedKey()])
        return value
    }

    private mutating func genericDecode<T: LosslessStringConvertible>() throws -> T {
        let value = try data.decode(key: codingPath + [nextIndexedKey()])
        let convertedOpt = T(value)
        guard let converted = convertedOpt else {
            throw DecodingError.typeMismatch(
                T.Type.self,
                DecodingError.Context(codingPath: codingPath + [nextIndexedKey()], debugDescription: "invalid value"))
        }
        return converted
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try genericDecode()
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try genericDecode()
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try genericDecode()
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try genericDecode()
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try genericDecode()
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try genericDecode()
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try genericDecode()
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try genericDecode()
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try genericDecode()
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try genericDecode()
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try genericDecode()
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try genericDecode()
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let stringsDecoding = StringsDecoding(from: data, codingPath: codingPath + [nextIndexedKey()])
        return try .init(from: stringsDecoding)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedDecodingContainer<NestedKey> {
        let container = StringsKeyedDecoding<NestedKey>(from: data, codingPath: codingPath + [nextIndexedKey()])
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let container = StringsUnkeyedDecoding(from: data, codingPath: codingPath + [nextIndexedKey()])
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        let stringsDecoding = StringsDecoding(from: data, codingPath: codingPath + [nextIndexedKey()])
        return stringsDecoding
    }
}

private struct StringsSingleValueDecoding: SingleValueDecodingContainer {

    private let data: CodingData

    init(from data: CodingData, codingPath: [CodingKey]) {
        self.data = data
        self.codingPath = codingPath
    }

    var codingPath: [CodingKey] = []

    func decodeNil() -> Bool {
        !data.contains(key: codingPath)
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        let value = try data.decode(key: codingPath)
        guard value == "true" || value == "false" else {
            throw DecodingError.typeMismatch(
                Bool.Type.self, DecodingError.Context(codingPath: codingPath, debugDescription: "invalid value"))
        }
        return value == "true"
    }

    func decode(_ type: String.Type) throws -> String {
        let value = try data.decode(key: codingPath)
        return value
    }

    private func genericDecode<T: LosslessStringConvertible>() throws -> T {
        let value = try data.decode(key: codingPath)
        let convertedOpt = T(value)
        guard let converted = convertedOpt else {
            throw DecodingError.typeMismatch(
                T.Type.self, DecodingError.Context(codingPath: codingPath, debugDescription: "invalid value"))
        }
        return converted
    }

    func decode(_ type: Double.Type) throws -> Double {
        try genericDecode()
    }

    func decode(_ type: Float.Type) throws -> Float {
        try genericDecode()
    }

    func decode(_ type: Int.Type) throws -> Int {
        try genericDecode()
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try genericDecode()
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try genericDecode()
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try genericDecode()
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try genericDecode()
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try genericDecode()
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try genericDecode()
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try genericDecode()
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try genericDecode()
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try genericDecode()
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let stringsDecoding = StringsDecoding(from: data, codingPath: codingPath)
        return try .init(from: stringsDecoding)
    }
}
