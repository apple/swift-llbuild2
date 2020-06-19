// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import SwiftProtobuf
import Foundation

/// Convenience protocol for referencing build system specific keys.
public protocol LLBBuildKey: LLBKey {
    /// Return a globally unique value that identifies a particular key type.
    static var identifier: LLBBuildKeyIdentifier { get }
}

/// Convenience protocol for referencing build system specific values.
public protocol LLBBuildValue: LLBValue, LLBSerializable {}

/// Identifier type for each type of build system specific key.
public typealias LLBBuildKeyIdentifier = String

/// Convenience implementation for keys that extend SwiftProtobuf.Message.
extension LLBBuildKey where Self: SwiftProtobuf.Message {
    public static var identifier: LLBBuildKeyIdentifier {
        return Self.protoMessageName
    }
}

