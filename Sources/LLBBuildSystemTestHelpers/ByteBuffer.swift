// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Foundation

public extension LLBByteBuffer {
    /// Helper extension for creating LLBByteBuffers from Data.
    static func withData(_ data: Data) -> LLBByteBuffer {
        return self.withBytes(ArraySlice<UInt8>(data))
    }
}
