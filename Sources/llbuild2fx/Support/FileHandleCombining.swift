// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

/// Creates a new FileHandle that, when written to, writes to all of the provided handles.
/// Calling this function with a single handle simply returns the given handle, so callers don't need to handle that case specially.
public func writingHandle(combining handles: any Collection<FileHandle>)
    -> FileHandle
{
    if handles.count == 1 { return handles.first! }

    let pipe = Pipe()
    // We use the `readabilityHandler` api instead of the `bytes` async sequence api because `readabilityHandler` lets us keep the chunking of writes intact. (Instead of creating a new write for every byte.)
    pipe.fileHandleForReading.readabilityHandler = { readHandle in
        let data = readHandle.availableData

        for writeHandle in handles {
            writeHandle.write(data)
        }

        if data.isEmpty {
            // FileHandle signals the end of the stream by sending empty data to readabilityHandler.
            // In this case, we clean up by detaching the handler.
            // (We still send the empty data to the backing file handles so they can perform their own cleanup.)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    return pipe.fileHandleForWriting
}
