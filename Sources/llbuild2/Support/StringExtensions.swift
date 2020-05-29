// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation


extension String {
    @inlinable
    public init(llbFromUTF8 bytes: Array<UInt8>) {
        if let string = bytes.withContiguousStorageIfAvailable({ bptr in
            String(decoding: bptr, as: UTF8.self)
        }) {
            self = string
        } else {
            self = bytes.withUnsafeBufferPointer { ubp in
                String(decoding: ubp, as: UTF8.self)
            }
        }
    }

    @inlinable
    public init(llbFromUTF8 bytes: ArraySlice<UInt8>) {
        if let string = bytes.withContiguousStorageIfAvailable({ bptr in
            String(decoding: bptr, as: UTF8.self)
        }) {
            self = string
        } else {
            self = bytes.withUnsafeBufferPointer { ubp in
                String(decoding: ubp, as: UTF8.self)
            }
        }
    }

    @inlinable
    public init(llbFromUTF8 bytes: Data) {
        self = String(decoding: bytes, as: UTF8.self)
    }
}
