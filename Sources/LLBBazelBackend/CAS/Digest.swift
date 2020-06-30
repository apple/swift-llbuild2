// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import llbuild2
import BazelRemoteAPI
import Crypto
import SwiftProtobuf
import TSCUtility

typealias Digest = Build_Bazel_Remote_Execution_V2_Digest

/// A Bazel digest.
extension Digest {
    public init<D>(with bytes: D) where D : DataProtocol {
        // Translate to SHA256.
        var hashFunction = Crypto.SHA256()
        hashFunction.update(data: bytes)
        let cryptoDigest = hashFunction.finalize()

        var hashBytes = Data()
        cryptoDigest.withUnsafeBytes { ptr in
            hashBytes.append(contentsOf: ptr)
        }

        self = .with {
            $0.hash = hexEncode(hashBytes)
            $0.sizeBytes = Int64(bytes.count)
        }
    }

    func asDataID() throws -> LLBDataID {
        return LLBDataID(directHash: Array(try self.serializedData()))
    }
}

extension LLBDataID {
    func asBazelDigest() throws -> Digest {
        return try bytes.dropFirst().withUnsafeBytes {
            try Digest.init(serializedData: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!), count: $0.count, deallocator: .none)) }
    }
}

extension SwiftProtobuf.Message {
    func asDigest() throws -> Digest {
        let bytes = [UInt8](try self.serializedData())
        return Digest(with: bytes)
    }
}
