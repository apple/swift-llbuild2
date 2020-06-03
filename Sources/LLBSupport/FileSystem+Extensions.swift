// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic

extension FileSystemError {
    public init(errno: CInt) {
        switch errno {
        case EACCES:
            self = .invalidAccess
        case EISDIR:
            self = .isDirectory
        case ENOENT:
            self = .noEntry
        case ENOTDIR:
            self = .notDirectory
        default:
            self = .unknownOSError
        }
    }
}


extension dirent {
    /// Get the directory name.
    ///
    /// This returns nil if the name is not valid UTF8.
    public var name: String? {
        var d_name = self.d_name
        return withUnsafePointer(to: &d_name) {
            String(validatingUTF8: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }
}
