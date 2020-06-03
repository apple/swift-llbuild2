// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic


// MARK:- DataID Definition -

/// An identifier that uniquely identifies a CAS object (i.e. a hash).
public struct LLBDataID: Hashable, CustomDebugStringConvertible {
    private enum IDKind: UInt8 {
        /// An id that is directly calculated based on a hash of the data.
        case directHash = 0
    }

    private let kind: IDKind

    /// The raw byte representation of the DataID
    public let bytes: [UInt8]

    /// Represent DataID as string to encode it in messages.
    /// Properties of the string: the first character represents the kind,
    /// then '~', then the Base64 encoding follows.
    public var debugDescription: String {
        return "\(bytes.dropFirst().base64URL(prepending: [UInt8(ascii: "0") + kind.rawValue, UInt8(ascii: "~")]))"
    }
    
    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case let n where n < 2:
            return nil
        default:
            guard let kind = IDKind(rawValue: bytes[0]) else {
                return nil
            }
            self.kind = kind
            self.bytes = bytes
        }
    }

    public init(directHash bytes: [UInt8]) {
        self.kind = .directHash
        self.bytes = [self.kind.rawValue] + bytes
    }

    /// Initialize from the string form.
    public init?(string: String) {
        self.init(string: Substring(string))
    }

    public init?(string: Substring) {
        guard string.count >= 3 else {
            return nil
        }
        func Bytes(for kind: IDKind) -> [UInt8]? {
            let substr = string[string.index(string.startIndex, offsetBy: 2)...]
            return [UInt8](base64URL: substr, prepending: [kind.rawValue])
        }
        switch string[...string.index(string.startIndex, offsetBy: 1)] {
        case "0~":
            guard let bytes = Bytes(for: .directHash) else { return nil }
            self.kind = .directHash
            self.bytes = bytes
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

extension LLBDataID {
    public enum LLBDataIDSliceError: Error {
    case decoding(String)
    }

    @inlinable
    public init(rawBytes: ArraySlice<UInt8>) throws {
        guard let dataId = LLBDataID(bytes: Array(rawBytes)) else {
            throw LLBDataIDSliceError.decoding("from slice of size \(rawBytes.count)")
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
    public var sliceSizeEstimate: Int {
        return bytes.count
    }
}


// MARK:- DataID <-> Proto conversion -

public extension LLBDataID {
    var asProto: LLBPBDataID {
        return LLBPBDataID.with { $0.bytes = Data(self.bytes) }
    }

    /// Unsafe initializer only to be used for converting an LLBPBDataID that is known to have originated from
    /// and LLBDataID instance.
    init(_ proto: LLBPBDataID) {
        self = Self.init(bytes: Array(proto.bytes))!
    }
}

public extension LLBPBDataID {
    init(_ dataID: LLBDataID) {
        self = Self.with {
            $0.bytes = Data(dataID.bytes)
        }
    }
}
