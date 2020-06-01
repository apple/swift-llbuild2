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


/// A non-recursive representation of a filesystem object or its part.
public struct LLBFilesystemObject {
    public let path: AbsolutePath
    public let content: Content
    public let permissions: mode_t?

    public enum Content {
    /// Not an actual filesystem content, a placeholder.
    case ignore
    /// Create an empty file.
    case empty(size: UInt64, executable: Bool)
    /// Part of a file to be placed at a specified offset.
    case partial(data: LLBFastData, offset: UInt64)
    /// An entire file (possibly executable)
    case file(data: LLBFastData, executable: Bool)
    /// Symbolic link.
    case symlink(target: String)
    /// An (empty) directory.
    case directory
    }

    public init() {
        self.path = AbsolutePath("/")
        self.content = Content.ignore
        self.permissions = nil
    }

    public init(_ path: AbsolutePath, _ content: Content, permissions: mode_t? = nil) {
        self.path = path
        self.content = content
        self.permissions = permissions
    }
}


/// Expose accounting stats.
extension LLBFilesystemObject {

    // Number of bytes represented by this FilesystemObject.
    var accountedDataSize: Int {
        switch self.content {
        case .ignore, .empty:
            return 0
        case let .partial(data, _):
            return data.count
        case let .file(data, _):
            return data.count
        case let .symlink(target):
            return target.utf8.count
        case .directory:
            return 0
        }
    }

    // Number of objects represented by this FilesystemObject.
    var accountedObjects: Int {
        switch content {
        case .ignore, .partial:
            return 0
        default:
            return 1
        }
    }

}
