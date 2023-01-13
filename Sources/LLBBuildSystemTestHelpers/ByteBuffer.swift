// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Foundation
import NIOCore

/// Helper extension for creating LLBByteBuffers from Data.
public extension LLBByteBuffer {

    static func withData(_ data: Data) -> LLBByteBuffer {
        return self.withBytes(ArraySlice<UInt8>(data))
    }

    static func withString(_ string: String) -> LLBByteBuffer {
        return self.withBytes(ArraySlice<UInt8>(string.utf8))
    }

    func asString() -> String? {
        return String(data: Data(self.readableBytesView), encoding: .utf8)
    }
}
