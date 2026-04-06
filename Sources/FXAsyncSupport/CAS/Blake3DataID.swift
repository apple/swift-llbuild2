// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import FXCBLAKE3
import NIOCore

extension FXDataID {
    package init(blake3hash buffer: FXByteBuffer, refs: [FXDataID] = []) {
        var hasher = fx_blake3_hasher()
        fx_blake3_hasher_init(&hasher)

        for ref in refs {
            ref.bytes.withUnsafeBytes { content in
                fx_blake3_hasher_update(&hasher, content.baseAddress, content.count)
            }
        }
        buffer.withUnsafeReadableBytes { data in
            fx_blake3_hasher_update(&hasher, data.baseAddress, data.count)
        }

        let hash = [UInt8](unsafeUninitializedCapacity: Int(BLAKE3_OUT_LEN)) { (hash, len) in
            len = Int(BLAKE3_OUT_LEN)
            fx_blake3_hasher_finalize(&hasher, hash.baseAddress, len)
        }

        self.init(directHash: hash)
    }

    package init(blake3hash data: [UInt8], refs: [FXDataID] = []) {
        self.init(blake3hash: ArraySlice(data))
    }
    package init(blake3hash string: String, refs: [FXDataID] = []) {
        self.init(blake3hash: ArraySlice(string.utf8))
    }

    package init(blake3hash slice: ArraySlice<UInt8>, refs: [FXDataID] = []) {
        var hasher = fx_blake3_hasher()
        fx_blake3_hasher_init(&hasher)

        for ref in refs {
            ref.bytes.withUnsafeBytes { content in
                fx_blake3_hasher_update(&hasher, content.baseAddress, content.count)
            }
        }
        slice.withUnsafeBytes { data in
            fx_blake3_hasher_update(&hasher, data.baseAddress, data.count)
        }

        let hash = [UInt8](unsafeUninitializedCapacity: Int(BLAKE3_OUT_LEN)) { (hash, len) in
            len = Int(BLAKE3_OUT_LEN)
            fx_blake3_hasher_finalize(&hasher, hash.baseAddress, len)
        }

        self.init(directHash: hash)
    }
}
