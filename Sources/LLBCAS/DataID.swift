// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic

import LLBSupport


// MARK:- DataID Extensions -

fileprivate enum DataIDKind: UInt8 {
    /// An id that is directly calculated based on a hash of the data.
    case directHash = 0
}


extension LLBDataID: Hashable, CustomDebugStringConvertible {
    /// Represent DataID as string to encode it in messages.
    /// Properties of the string: the first character represents the kind,
    /// then '~', then the Base64 encoding follows.
    public var debugDescription: String {
        return "\(ArraySlice(bytes.dropFirst()).base64URL(prepending: [UInt8(ascii: "0") + bytes[0], UInt8(ascii: "~")]))"
    }
    
    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case let n where n < 2:
            return nil
        default:
            guard DataIDKind(rawValue: bytes[0]) != nil else {
                return nil
            }
            self.bytes = Data(bytes)
        }
    }

    public init(directHash bytes: [UInt8]) {
        self.bytes = Data([DataIDKind.directHash.rawValue] + bytes)
    }

    /// Initialize from the string form.
    public init?(string: String) {
        self.init(string: Substring(string))
    }

    public init?(string: Substring) {
        guard string.count >= 3 else {
            return nil
        }
        func Bytes(for kind: DataIDKind) -> [UInt8]? {
            let substr = string[string.index(string.startIndex, offsetBy: 2)...]
            return [UInt8](base64URL: substr, prepending: [kind.rawValue])
        }
        switch string[...string.index(string.startIndex, offsetBy: 1)] {
        case "0~":
            guard let bytes = Bytes(for: .directHash) else { return nil }
            self.bytes = Data(bytes)
        default:
            return nil
        }
    }
}


extension LLBDataID: Comparable {
    /// Compare DataID according to stable but arbitrary rules
    /// (not necessarily alphanumeric).
    public static func < (lhs: LLBDataID, rhs: LLBDataID) -> Bool {
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

extension LLBDataID: Codable {
    public enum LLBDataIDCodingError: Error {
        case decoding(String)
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let dataId = LLBDataID(string: string) else {
            throw LLBDataIDCodingError.decoding("invalid DataID encoding: '\(string)'")
        }
        self = dataId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.debugDescription)
    }
}


// MARK:- raw byte interfaces -

extension LLBDataID: LLBSerializable {
    public enum LLBDataIDSliceError: Error {
    case decoding(String)
    }

    @inlinable
    public init(from rawBytes: ArraySlice<UInt8>) throws {
        guard let dataId = LLBDataID(bytes: Array(rawBytes)) else {
            throw LLBDataIDSliceError.decoding("from slice of size \(rawBytes.count)")
        }
        self = dataId
    }

    @inlinable
    public init(from rawBytes: LLBByteBuffer) throws {
        guard let bytes = rawBytes.getBytes(at: 0, length: rawBytes.readableBytes), let dataId = LLBDataID(bytes: bytes) else {
            throw LLBDataIDSliceError.decoding("from slice of size \(rawBytes.readableBytes)")
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
    public func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeBytes(bytes)
    }

    @inlinable
    public var sliceSizeEstimate: Int {
        return bytes.count
    }
}

