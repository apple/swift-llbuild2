// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import ZSTD

import LLBCAS
import LLBSupport


public enum LLBCASBlobError: Error {
    case missingObject
    case notABlob
    case unexpectedEncoding
    case uncompressFailed
    case badRange
}

/// A wrapper for accessing CASTree file contents.
public struct LLBCASBlob {
    // FIXME: The logic in this clase is intimately tied to `CASTreeParser`, it
    // should be unified.

    enum Contents {
        /// The object is a single flat data array.
        ///
        /// This is stored as a future so it can be either the constant data, or
        /// the data fetched from an object that indirectly references a flat
        /// blob.
        case flat(innerID: LLBDataID, LLBFuture<LLBByteBuffer>)

        /// The object is chunked with a fixed size.
        case chunked(chunks: [LLBDataID], chunkSize: Int)
    }

    enum TypedID {
        case inner(LLBDataID)
        case outer(LLBDataID)
    }

    /// The database to access within.
    public let db: LLBCASDatabase

    /// ID as it came in.
    internal let receivedId: TypedID

    /// The size of the blob.
    public let size: Int

    /// The type of the blob.
    internal let type: LLBFileType

    /// The parsed information on the object.
    private let contents: Contents

    /// Split big binaries to chunks of this size
    static let maxChunkSize = 8 * 1024 * 1024

    public static func parse(id: LLBDataID, in db: LLBCASDatabase) -> LLBFuture<LLBCASBlob> {
        return db.get(id).flatMapThrowing { object in
            guard let object = object else { throw LLBCASBlobError.missingObject }

            return try LLBCASBlob(db: db, id: id, object: object)
        }
    }

    internal init(db: LLBCASDatabase, receivedId: TypedID, type: LLBFileType, size: Int, contents: Contents) {
        self.db = db
        self.receivedId = receivedId
        self.type = type
        self.size = size
        self.contents = contents
    }

    public init(db: LLBCASDatabase, id: LLBDataID, object: LLBCASObject) throws {
        self = try Self(db: db, id: id, type: .plainFile, object: object)
    }

    internal init(db: LLBCASDatabase, id: LLBDataID, type advertisedType: LLBFileType, object: LLBCASObject) throws {
        self.db = db

        // Parse the object.
        if object.refs.isEmpty {
            // If the object has no refs, it must be a old-style or trivial uncompressed blob.
            self.size = object.data.readableBytes
            self.type = advertisedType
            self.receivedId = .inner(id)
            self.contents = .flat(innerID: id, db.group.next().makeSucceededFuture(object.data))
            return
        }

        // Otherwise, we must have a complex object, which will be described by
        // the `FileInformation` type.
        let info = try LLBFileInfo.deserialize(from: object.data)
        self.size = Int(info.size)

        self.type = info.type
        self.receivedId = .outer(id)

        // Check the type is actually a blob we understand.
        guard info.type == .plainFile || info.type == .executable else {
            throw LLBCASBlobError.notABlob
        }

        guard case .fixedChunkSize(let chunkSize) = info.payload else {
            throw LLBCASBlobError.notABlob
        }

        // If the chunk size matches the file size, we should have a single flat entry.
        if chunkSize == size {
            guard let ref = object.refs.first, object.refs.count == 1 else {
                throw LLBCASBlobError.unexpectedEncoding
            }

            let future: LLBFuture<LLBByteBuffer> = db.get(ref).flatMapThrowing { object in
                guard let object = object else {
                    throw LLBCASBlobError.missingObject
                }
                return object.data
            }

            self.contents = .flat(innerID: id, future)
            return
        }

        // Otherwise, we have a properly chunked blob.
        self.contents = .chunked(chunks: object.refs, chunkSize: Int(chunkSize))
    }

    /// Read a range of bytes.
    ///
    /// NOTE: This function is not currently as efficient as it should be (as it
    /// may require allocation of temporary buffers to provide a contiguous
    /// view, and it cannot accomodate that the underlying object may be loaded
    /// at separate points in time).
    public func read() -> LLBFuture<LLBByteBufferView> {
        read(range: 0..<size)
    }

    public func read(range: Range<Int>) -> LLBFuture<LLBByteBufferView> {
        guard range.lowerBound >= 0, range.upperBound <= size else {
            return db.group.next().makeFailedFuture(LLBCASBlobError.badRange)
        }
        switch contents {
        case .flat(_, let dataFuture):
            return dataFuture.map { data in
                let view = LLBByteBufferView(data)
                return view[range.relative(to: view)]
            }
        case .chunked(let chunks, let chunkSize):
            // Read each chunk.
            let startChunk = range.lowerBound / chunkSize
            let endChunk = max(range.lowerBound, min(self.size, range.upperBound) - 1) / chunkSize + 1

            // If the read is in one chunk, do the simple thing.
            assert(endChunk > startChunk)
            if endChunk - startChunk == 1 {
                let chunkStart = startChunk * chunkSize
                return readFromOneChunk(id: chunks[startChunk],
                    range: (range.lowerBound-chunkStart)..<(range.upperBound-chunkStart))
            }

            // Otherwise, dispatch all the individual reads.
            let fs: [LLBFuture<LLBByteBufferView>] = (startChunk ..< endChunk).map { i in
                let chunkStart = i * chunkSize
                let offset = max(range.lowerBound, chunkStart) - chunkStart
                let endOffset = min(range.upperBound - chunkStart, chunkSize)
                return readFromOneChunk(id: chunks[i], range: offset ..< endOffset)
            }

            // FIXME: This is rather inefficient; we could at least alloc a
            // single buffer and just write into it.
            return LLBFuture.whenAllSucceed(fs, on: db.group.next()).map { results in
                var combined = LLBByteBufferAllocator().buffer(capacity: range.count)
                for item in results {
                    combined.writeBytes(item)
                }
                return LLBByteBufferView(combined)
            }
        }
    }

    /// Read a range from a chunked object.
    private func readFromOneChunk(id: LLBDataID, range: Range<Int>) -> LLBFuture<LLBByteBufferView> {
        return db.get(id).flatMap { object in
            guard let object = object else {
                return self.db.group.next().makeFailedFuture(LLBCASBlobError.missingObject)
            }

            // If this object has no refs, it is the chunk itself.
            if object.refs.isEmpty {
                let view = LLBByteBufferView(object.data)
                return self.db.group.next().makeSucceededFuture(
                    view[range.relative(to: view)])
            }

            // Otherwise, it is an annotated item; current, we expect this only
            // happens when compression is enabled.
            let info: LLBFileInfo
            do {
                info = try LLBFileInfo.deserialize(from: object.data)
            } catch {
                return self.db.group.next().makeFailedFuture(error)
            }
            guard info.type == .plainFile || info.type == .executable,
                  case .fixedChunkSize(let overestimatedSize) = info.payload,
                  object.refs.count == 1,
                  info.compression != .none else {
                return self.db.group.next().makeFailedFuture(LLBCASBlobError.unexpectedEncoding)
            }

            return self.db.get(object.refs[0]).flatMapThrowing { object in
                guard let object = object else {
                    throw LLBCASBlobError.missingObject
                }

                let zstd = ZSTDStream()
                try zstd.startDecompression()
                let allocator = LLBByteBufferAllocator()
                var decompressed = allocator.buffer(capacity: max(3 * (1 + object.data.readableBytes), Int(clamping: overestimatedSize)))
                var isDone = false
                try object.data.withUnsafeReadableBytes { ptr in
                    _ = try zstd.decompress(input: ptr, into: &decompressed, isDone: &isDone)
                }
                guard isDone else {
                    throw LLBCASBlobError.uncompressFailed
                }

                // FIXME: This needs to be optimized; we should instead write
                // directly into the result buffer.
                let view = LLBByteBufferView(decompressed)
                return view[range.relative(to: view)]
            }
        }
    }

    /// Represent a single file in a CASFSNode-compatible format.
    /// Since CASFSNode can't represent a single file yet, this will
    /// return a DataID of the file info object directly.
    public static func `import`(data: LLBByteBuffer, isExecutable: Bool = false, in db: LLBCASDatabase) -> LLBFuture<LLBCASBlob> {

        guard isExecutable || data.readableBytes > Self.maxChunkSize else {
            // If a plain file, just put the file directly.
            // FIXME: large files should be split.
            return db.put(refs: [], data: data).map { id in
                LLBCASBlob(db: db, receivedId: .inner(id),
                    type: .plainFile,
                    size: data.readableBytes,
                    contents: .flat(innerID: id, db.group.next().makeSucceededFuture(data)))
            }
        }

        var fileInfo = LLBFileInfo()
        fileInfo.type = isExecutable ? .executable : .plainFile
        fileInfo.size = UInt64(data.readableBytes)
        fileInfo.compression = .none
        fileInfo.fixedChunkSize = UInt64(data.readableBytes) // TODO: Split
        return db.put(refs: [], data: data).flatMap { blobId in
            do {
                return db.put(refs: [blobId], data: try fileInfo.toBytes()).map { outerId in
                    LLBCASBlob(db: db, receivedId: .outer(outerId),
                        type: fileInfo.type,
                        size: data.readableBytes,
                        contents: .chunked(chunks: [blobId], chunkSize: Int(fileInfo.fixedChunkSize)))
                }
            } catch {
                return db.group.next().makeFailedFuture(error)
            }
        }
    }

    private func chunkIDs() -> [LLBDataID] {
        switch contents {
        case let .flat(innerID, _):
            return [innerID]
        case let .chunked(chunks, _):
            assert(chunks.count >= 1)
            return chunks
        }
    }

    /// Create an 'exportable' version of the blob, the one that reconstructs
    /// into the same bytes when imported.
    /// FIXME: This export should be available only through CASFSNode.
    public func export() -> LLBFuture<LLBDataID> {
        switch receivedId {
        case .outer(let id):
            return db.group.next().makeSucceededFuture(id)
        case .inner(let id):
            let chunks = chunkIDs()
            if let chunk = chunks.first, chunks.count == 1, type == .plainFile {
                return db.group.next().makeSucceededFuture(chunk)
            }
            var fileInfo = LLBFileInfo()
            fileInfo.type = type
            fileInfo.size = UInt64(size)
            fileInfo.compression = .none
            fileInfo.fixedChunkSize = UInt64(size) // TODO: Split
            do {
                return db.put(refs: [id], data: try fileInfo.toBytes())
            } catch {
                return db.group.next().makeFailedFuture(error)
            }
        }
    }

    public func asDirectoryEntry(filename: String) -> LLBDirectoryEntryID {
        let chunks = chunkIDs()
        if let chunk = chunks.first, chunks.count == 1 {
            return LLBDirectoryEntryID(info: .init(name: filename, type: type, size: size), id: chunk)
        }
        switch receivedId {
        case .outer(let id):
            return LLBDirectoryEntryID(info: .init(name: filename, type: type, size: size), id: id)
        case .inner(_):
            fatalError("Multichunk blob cannot be represented with inner id")
        }
    }
}
