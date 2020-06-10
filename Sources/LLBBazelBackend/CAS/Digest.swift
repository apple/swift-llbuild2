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


/// A Bazel digest.
struct Digest: Hashable {
    let hash: String
    let size: Int64

    init(hash: String, size: Int64) {
        self.hash = hash
        self.size = size
    }

    init<D>(with bytes: D) where D : DataProtocol {
        // Translate to SHA256.
        var hashFunction = Crypto.SHA256()
        hashFunction.update(data: bytes)
        let cryptoDigest = hashFunction.finalize()

        var hashBytes = Data()
        cryptoDigest.withUnsafeBytes { ptr in
            hashBytes.append(contentsOf: ptr)
        }

        self.hash = hexEncode(hashBytes)
        self.size = Int64(bytes.count)
    }

    func asBytes() throws -> [UInt8] {
        return Array(try self.asBazelDigest.serializedData())
    }

    var asBazelDigest: Build_Bazel_Remote_Execution_V2_Digest {
        return .with {
            $0.hash = self.hash
            $0.sizeBytes = self.size
        }
    }

    func asDataID() throws -> LLBDataID {
        return LLBDataID(directHash: try self.asBytes())
    }
}

extension Build_Bazel_Remote_Execution_V2_Digest {
    var asDigest: Digest {
        return Digest(hash: hash, size: sizeBytes)
    }
}

extension LLBDataID {
    func asBazelDigest() throws -> Build_Bazel_Remote_Execution_V2_Digest {
        return try bytes.dropFirst().withUnsafeBytes {
            try Build_Bazel_Remote_Execution_V2_Digest.init(serializedData: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!), count: $0.count, deallocator: .none)) }
    }
}

extension SwiftProtobuf.Message {
    func asDigest() throws -> Digest {
        let bytes = [UInt8](try self.serializedData())
        return Digest(with: bytes)
    }
}
