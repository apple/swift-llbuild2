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

    init(with bytes: [UInt8]) {
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

    var asBytes: [UInt8] {
        // FIXME: This is not efficient.
        return Array((hash + String(size)).utf8)
    }

    var asBazelDigest: Build_Bazel_Remote_Execution_V2_Digest {
        return .with {
            $0.hash = self.hash
            $0.sizeBytes = self.size
        }
    }
}

extension Build_Bazel_Remote_Execution_V2_Digest {
    var asDigest: Digest {
        return Digest(hash: hash, size: sizeBytes)
    }
}

extension LLBDataID {
    var asBazelDigest: Build_Bazel_Remote_Execution_V2_Digest {
        return .with {
            $0.hash = hexEncode(self.bytes.dropFirst())
            $0.sizeBytes = Int64(self.bytes.count - 1)
        }
    }
}

extension SwiftProtobuf.Message {
    func asDigest() throws -> Digest {
        let bytes = [UInt8](try self.serializedData())
        return Digest(with: bytes)
    }
}
