// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCBasic

import LLBCAS


public enum LLBCASFileTreeFormatError: Error {
    /// The given id was referenced as a directory, but the object encoding didn't match expectations.
    case unexpectedDirectoryData(LLBDataID)

    /// The given id was referenced as a file, but the object encoding didn't match expectations.
    case unexpectedFileData(LLBDataID)

    /// The given id was referenced as a symlink, but the object encoding didn't match expectations.
    case unexpectedSymlinkData(LLBDataID)

    /// An unexpected error was thrown while communicating with the database.
    case unexpectedDatabaseError(Error)

    /// Formatting/protocol error.
    case formatError(reason: String)

    /// File size exceeds internal limits
    case fileTooLarge(path: AbsolutePath)

    /// Decompression failed
    case decompressFailed(path: AbsolutePath)
}

