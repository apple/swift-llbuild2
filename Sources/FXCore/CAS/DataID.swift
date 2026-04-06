// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSCBasic

// MARK:- DataID Extensions -

private enum DataIDKind: UInt8 {
    /// An id that is directly calculated based on a hash of the data.
    case directHash = 0
    case shareableHash = 4

    init?(from bytes: Data) {
        guard let first = bytes.first,
            let kind = DataIDKind(rawValue: first)
        else {
            return nil
        }
        self = kind
    }

    init?(from substring: Substring) {
        guard let first = substring.utf8.first,
            first >= UInt8(ascii: "0")
        else {
            return nil
        }
        self.init(rawValue: first - UInt8(ascii: "0"))
    }
}

extension FXDataID: Hashable, CustomDebugStringConvertible {

    /// Represent DataID as string to encode it in messages.
    /// Properties of the string: the first character represents the kind,
    /// then '~', then the Base64 encoding follows.
    public var debugDescription: String {
        return ArraySlice(bytes.dropFirst()).base64URL(prepending: [
            (bytes.first ?? 15) + UInt8(ascii: "0"), UInt8(ascii: "~"),
        ])
    }

    public init?(bytes: [UInt8]) {
        let data = Data(bytes)
        guard DataIDKind(from: data) != nil else {
            return nil
        }
        self.bytes = data
    }

    public init(directHash bytes: [UInt8]) {
        self.bytes = Data([DataIDKind.directHash.rawValue] + bytes)
    }

    /// Initialize from the string form.
    public init?(string: String) {
        self.init(string: Substring(string))
    }

    public init?(string: Substring) {
        // Test for the kind in the first position.
        guard let kind = DataIDKind(from: string) else { return nil }

        // Test for "~" in the second position.
        guard string.count >= 2 else { return nil }
        let tilde = string.utf8[string.utf8.index(string.startIndex, offsetBy: 1)]
        guard tilde == UInt8(ascii: "~") else { return nil }

        let b64substring = string.dropFirst(2)
        guard let completeBytes = [UInt8](base64URL: b64substring, prepending: [kind.rawValue])
        else {
            return nil
        }

        self.bytes = Data(completeBytes)
    }
}

extension FXDataID: Comparable {
    /// Compare DataID according to stable but arbitrary rules
    /// (not necessarily alphanumeric).
    public static func < (lhs: FXDataID, rhs: FXDataID) -> Bool {
        let a = lhs.bytes
        let b = rhs.bytes
        if a.count == b.count {
            for n in (0..<a.count) {
                if a[n] != b[n] {
                    return a[n] < b[n]
                }
            }
            return false
        } else {
            return a.count < b.count
        }
    }
}

// MARK:- Codable support for DataID -

extension FXDataID: Codable {
    public enum FXDataIDCodingError: Error {
        case decoding(String)
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let dataId = FXDataID(string: string) else {
            throw FXDataIDCodingError.decoding("invalid DataID encoding: '\(string)'")
        }
        self = dataId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.debugDescription)
    }
}

// MARK:- raw byte interfaces -

extension FXDataID: FXSerializable {
    public enum FXDataIDSliceError: Error {
        case decoding(String)
    }

    @inlinable
    public init(from rawBytes: ArraySlice<UInt8>) throws {
        guard let dataId = FXDataID(bytes: Array(rawBytes)) else {
            throw FXDataIDSliceError.decoding("from slice of size \(rawBytes.count)")
        }
        self = dataId
    }

    @inlinable
    public init(from rawBytes: FXByteBuffer) throws {
        guard let dataId = FXDataID(bytes: Array(buffer: rawBytes)) else {
            throw FXDataIDSliceError.decoding("from slice of size \(rawBytes.readableBytes)")
        }
        self = dataId
    }

    @inlinable
    public func toBytes() -> ArraySlice<UInt8> {
        return ArraySlice(bytes)
    }

    @inlinable
    public func toBytes(into array: inout [UInt8]) {
        array += bytes
    }

    @inlinable
    public func toBytes(into buffer: inout FXByteBuffer) throws {
        buffer.writeBytes(bytes)
    }

    @inlinable
    public var sliceSizeEstimate: Int {
        return bytes.count
    }
}
