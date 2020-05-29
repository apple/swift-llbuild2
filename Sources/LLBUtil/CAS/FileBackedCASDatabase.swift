// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import TSCBasic
import TSCLibc
import Foundation

public final class LLBFileBackedCASDatabase: LLBCASDatabase {
    /// Prefix for files written to disk.
    enum FileNamePrefix: String {
        case refs = "refs."
        case data = "data."
    }

    /// The content root path.
    public let path: AbsolutePath

    /// Threads capable of running futures.
    public let group: LLBFuturesDispatchGroup

    public init(
        group: LLBFuturesDispatchGroup,
        path: AbsolutePath
    ) {
        self.group = group
        self.path = path
        try? localFileSystem.createDirectory(path, recursive: true)
    }

    private func fileName(for id: LLBDataID, prefix: FileNamePrefix) -> AbsolutePath {
        return path.appending(component: prefix.rawValue + id.debugDescription)
    }

    public func supportedFeatures() -> LLBFuture<LLBCASFeatures> {
        group.next().makeSucceededFuture(LLBCASFeatures(preservesIDs: true))
    }

    public func contains(_ id: LLBDataID) -> LLBFuture<Bool> {
        let refsFile = fileName(for: id, prefix: .refs)
        let dataFile = fileName(for: id, prefix: .data)
        let contains = localFileSystem.exists(refsFile) && localFileSystem.exists(dataFile)
        return group.next().makeSucceededFuture(contains)
    }

    public func get(_ id: LLBDataID) -> LLBFuture<LLBCASObject?> {
        let refsFile = fileName(for: id, prefix: .refs)
        let dataFile = fileName(for: id, prefix: .data)

        do {
            let data = try fs.readFileContents(dataFile)
            let refsData = try fs.readFileContents(refsFile)
            let refs = try JSONDecoder().decode([LLBDataID].self, from: Data(refsData.contents))
            let result = LLBCASObject(refs: refs, data: LLBByteBuffer.withBytes(data.contents[...]))
            return group.next().makeSucceededFuture(result)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    var fs: FileSystem { localFileSystem }

    public func put(refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        put(knownID: LLBDataID(blake3hash: data, refs: refs), refs: refs, data: data)
    }

    public func put(knownID id: LLBDataID, refs: [LLBDataID], data: LLBByteBuffer) -> LLBFuture<LLBDataID> {
        do {
            let refsFile = fileName(for: id, prefix: .refs)
            let dataFile = fileName(for: id, prefix: .data)

            var sbData = stat()
            var sbRefs = stat()
            if stat(dataFile.pathString, &sbData) != -1 && stat(refsFile.pathString, &sbRefs) != -1 {
                // Assume some amount of file system atomicity, which means
                // that if we have this file, then:
                // 1. This file was properly written to completion, and reading
                //    from it will result in getting all the data.
                // 2. The references `refs` were written even earlier, and are
                //    also available.
                // One would only wish that these guarantees were available...
                assert(sbData.st_size == data.readableBytes, "Replacing \(id) with data of different length")
                return group.next().makeSucceededFuture(id)
            }

            let data = data.getBytes(at: 0, length: data.readableBytes)!
            try localFileSystem.writeFileContents(
                dataFile,
                bytes: ByteString(data),
                atomically: true
            )

            let refData = try JSONEncoder().encode(refs)
            try localFileSystem.writeFileContents(
                refsFile,
                bytes: ByteString(refData),
                atomically: true
            )
            return group.next().makeSucceededFuture(id)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }
}
