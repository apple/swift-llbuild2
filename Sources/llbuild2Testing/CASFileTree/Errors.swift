// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import TSCBasic

package enum FXCASFileTreeFormatError: Error {
    /// The given id was referenced as a directory, but the object encoding didn't match expectations.
    case unexpectedDirectoryData(FXDataID)

    /// The given id was referenced as a file, but the object encoding didn't match expectations.
    case unexpectedFileData(FXDataID)

    /// The given id was referenced as a symlink, but the object encoding didn't match expectations.
    case unexpectedSymlinkData(FXDataID)

    /// An unexpected error was thrown while communicating with the database.
    case unexpectedDatabaseError(Error)

    /// Formatting/protocol error.
    case formatError(reason: String)

    /// File size exceeds internal limits
    case fileTooLarge(path: AbsolutePath)

    /// Decompression failed
    case decompressFailed(String)
}
