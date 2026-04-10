// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import NIOCore
import TSCUtility

package enum FXCASBlobError: Error {
    case missingObject
    case notABlob
    case unexpectedEncoding
    case uncompressFailed
    case badRange
}

/// A wrapper for accessing CASTree file contents.
package struct FXCASBlob {
    // FIXME: The logic in this clase is intimately tied to `CASTreeParser`, it
    // should be unified.

    enum Contents {
        /// The object is a single flat data array.
        ///
        /// This is stored as a future so it can be either the constant data, or
        /// the data fetched from an object that indirectly references a flat
        /// blob.
        case flat(innerID: FXDataID, FXFuture<FXByteBuffer>)

        /// The object is chunked with a fixed size.
        case chunked(chunks: [FXDataID], chunkSize: Int)
    }

    enum TypedID {
        case inner(FXDataID)
        case outer(FXDataID)
    }

    /// The database to access within.
    package let db: any FXCASDatabase

    /// ID as it came in.
    internal let receivedId: TypedID

    /// The size of the blob.
    package let size: Int

    /// The type of the blob.
    internal let type: FXFileType

    /// POSIX permissions and ownership.
    internal let posixDetails: FXPosixFileDetails?

    /// The parsed information on the object.
    private let contents: Contents

    /// Split big binaries to chunks of this size
    static let maxChunkSize = 8 * 1024 * 1024

    package static func parse(id: FXDataID, in db: any FXCASDatabase, _ ctx: Context) -> FXFuture<
        FXCASBlob
    > {
        return db.get(id, ctx).flatMapThrowing { object in
            guard let object = object else { throw FXCASBlobError.missingObject }

            return try FXCASBlob(db: db, id: id, object: object, ctx)
        }
    }

    internal init(
        db: any FXCASDatabase, receivedId: TypedID, type: FXFileType,
        posixDetails: FXPosixFileDetails? = nil, size: Int, contents: Contents
    ) {
        self.db = db
        self.receivedId = receivedId
        self.type = type
        self.size = size
        self.posixDetails = posixDetails
        self.contents = contents
    }

    package init(db: any FXCASDatabase, id: FXDataID, object: FXCASObject, _ ctx: Context) throws {
        self = try Self(db: db, id: id, type: .plainFile, object: object, ctx)
    }

    internal init(
        db: any FXCASDatabase, id: FXDataID, type advertisedType: FXFileType, object: FXCASObject,
        _ ctx: Context
    ) throws {
        self.db = db

        // Parse the object.
        if object.refs.isEmpty {
            // If the object has no refs, it must be a old-style or trivial uncompressed blob.
            self.size = object.data.readableBytes
            self.type = advertisedType
            self.receivedId = .inner(id)
            self.posixDetails = nil
            self.contents = .flat(innerID: id, db.group.next().makeSucceededFuture(object.data))
            return
        }

        // Otherwise, we must have a complex object, which will be described by
        // the `FileInformation` type.
        let info = try FXFileInfo.deserialize(from: object.data)
        self.size = Int(info.size)

        self.type = info.type
        self.receivedId = .outer(id)

        self.posixDetails = info.hasPosixDetails ? info.posixDetails : nil

        // Check the type is actually a blob we understand.
        guard info.type == .plainFile || info.type == .executable else {
            throw FXCASBlobError.notABlob
        }

        guard case .fixedChunkSize(let chunkSize) = info.payload else {
            throw FXCASBlobError.notABlob
        }

        // If the chunk size matches the file size, we should have a single flat entry.
        if chunkSize == size {
            guard let ref = object.refs.first, object.refs.count == 1 else {
                throw FXCASBlobError.unexpectedEncoding
            }

            let future: FXFuture<FXByteBuffer> = db.get(ref, ctx).flatMapThrowing { object in
                guard let object = object else {
                    throw FXCASBlobError.missingObject
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
    package func read(_ ctx: Context) -> FXFuture<FXByteBufferView> {
        read(range: 0..<size, ctx)
    }

    package func read(range: Range<Int>, _ ctx: Context) -> FXFuture<FXByteBufferView> {
        guard range.lowerBound >= 0, range.upperBound <= size else {
            return db.group.next().makeFailedFuture(FXCASBlobError.badRange)
        }
        switch contents {
        case .flat(_, let dataFuture):
            return dataFuture.map { data in
                let view = FXByteBufferView(data)
                return view[range.relative(to: view)]
            }
        case .chunked(let chunks, let chunkSize):
            // Read each chunk.
            let startChunk = range.lowerBound / chunkSize
            let endChunk =
                max(range.lowerBound, min(self.size, range.upperBound) - 1) / chunkSize + 1

            // If the read is in one chunk, do the simple thing.
            assert(endChunk > startChunk)
            if endChunk - startChunk == 1 {
                let chunkStart = startChunk * chunkSize
                return readFromOneChunk(
                    id: chunks[startChunk],
                    range: (range.lowerBound - chunkStart)..<(range.upperBound - chunkStart), ctx)
            }

            // Otherwise, dispatch all the individual reads.
            let fs: [FXFuture<FXByteBufferView>] = (startChunk..<endChunk).map { i in
                let chunkStart = i * chunkSize
                let offset = max(range.lowerBound, chunkStart) - chunkStart
                let endOffset = min(range.upperBound - chunkStart, chunkSize)
                return readFromOneChunk(id: chunks[i], range: offset..<endOffset, ctx)
            }

            // FIXME: This is rather inefficient; we could at least alloc a
            // single buffer and just write into it.
            return FXFuture.whenAllSucceed(fs, on: db.group.next()).map { results in
                var combined = FXByteBufferAllocator().buffer(capacity: range.count)
                for item in results {
                    combined.writeBytes(item)
                }
                return FXByteBufferView(combined)
            }
        }
    }

    /// Read a range from a chunked object.
    private func readFromOneChunk(id: FXDataID, range: Range<Int>, _ ctx: Context) -> FXFuture<
        FXByteBufferView
    > {
        return db.get(id, ctx).flatMap { object in
            guard let object = object else {
                return self.db.group.next().makeFailedFuture(FXCASBlobError.missingObject)
            }

            // If this object has no refs, it is the chunk itself.
            if object.refs.isEmpty {
                let view = FXByteBufferView(object.data)
                return self.db.group.next().makeSucceededFuture(
                    view[range.relative(to: view)])
            }

            // Otherwise, it is an annotated item; current, we expect this only
            // happens when compression is enabled.
            let info: FXFileInfo
            do {
                info = try FXFileInfo.deserialize(from: object.data)
            } catch {
                return self.db.group.next().makeFailedFuture(error)
            }
            guard info.type == .plainFile || info.type == .executable,
                case .fixedChunkSize(_) = info.payload,
                object.refs.count == 1,
                info.compression != .none
            else {
                return self.db.group.next().makeFailedFuture(FXCASBlobError.unexpectedEncoding)
            }

            return self.db.get(object.refs[0], ctx).flatMapThrowing { object in
                guard object != nil else {
                    throw FXCASBlobError.missingObject
                }

                throw FXCASBlobError.uncompressFailed
            }
        }
    }

    /// Represent a single file in a CASFSNode-compatible format.
    /// Since CASFSNode can't represent a single file yet, this will
    /// return a DataID of the file info object directly.
    package static func `import`(
        data: FXByteBuffer, isExecutable: Bool = false, in db: any FXCASDatabase,
        posixDetails: FXPosixFileDetails? = nil, options: FXCASFileTree.ImportOptions? = nil,
        _ ctx: Context
    ) -> FXFuture<FXCASBlob> {

        let testId = FXDataID(blake3hash: data, refs: [])

        var fileInfo = FXFileInfo()
        fileInfo.type = isExecutable ? .executable : .plainFile
        fileInfo.size = UInt64(data.readableBytes)
        fileInfo.compression = .none
        fileInfo.fixedChunkSize = UInt64(data.readableBytes)  // TODO: Split
        if let pd = posixDetails {
            fileInfo.update(posixDetails: pd, options: options)
        }

        guard isExecutable || data.readableBytes > Self.maxChunkSize else {
            // If a plain file, just put the file directly.
            // FIXME: large files should be split.
            return db.contains(testId, ctx).flatMap { exists in
                exists ? db.group.next().makeSucceededFuture(testId) : db.put(data: data, ctx)
            }.map { id in
                FXCASBlob(
                    db: db, receivedId: .inner(id),
                    type: .plainFile,
                    posixDetails: fileInfo.hasPosixDetails ? fileInfo.posixDetails : nil,
                    size: data.readableBytes,
                    contents: .flat(innerID: id, db.group.next().makeSucceededFuture(data)))
            }
        }

        return db.contains(testId, ctx).flatMap { exists in
            exists ? db.group.next().makeSucceededFuture(testId) : db.put(data: data, ctx)
        }.flatMap { blobId in
            do {
                return db.put(refs: [blobId], data: try fileInfo.toBytes(), ctx).map { outerId in
                    FXCASBlob(
                        db: db, receivedId: .outer(outerId),
                        type: fileInfo.type,
                        posixDetails: fileInfo.hasPosixDetails ? fileInfo.posixDetails : nil,
                        size: data.readableBytes,
                        contents: .chunked(
                            chunks: [blobId], chunkSize: Int(fileInfo.fixedChunkSize)))
                }
            } catch {
                return db.group.next().makeFailedFuture(error)
            }
        }
    }

    private func chunkIDs() -> [FXDataID] {
        switch contents {
        case .flat(let innerID, _):
            return [innerID]
        case .chunked(let chunks, _):
            assert(chunks.count >= 1)
            return chunks
        }
    }

    /// Create an 'exportable' version of the blob, the one that reconstructs
    /// into the same bytes when imported.
    /// FIXME: This export should be available only through CASFSNode.
    package func export(_ ctx: Context) -> FXFuture<FXDataID> {
        switch receivedId {
        case .outer(let id):
            return db.group.next().makeSucceededFuture(id)
        case .inner(let id):
            let chunks = chunkIDs()
            if let chunk = chunks.first, chunks.count == 1, type == .plainFile {
                return db.group.next().makeSucceededFuture(chunk)
            }
            var fileInfo = FXFileInfo()
            fileInfo.type = type
            fileInfo.size = UInt64(size)
            fileInfo.compression = .none
            fileInfo.fixedChunkSize = UInt64(size)  // TODO: Split
            do {
                return db.put(refs: [id], data: try fileInfo.toBytes(), ctx)
            } catch {
                return db.group.next().makeFailedFuture(error)
            }
        }
    }

    package func asDirectoryEntry(filename: String) -> FXDirectoryEntryID {
        let chunks = chunkIDs()
        if let chunk = chunks.first, chunks.count == 1 {
            return FXDirectoryEntryID(
                info: .init(
                    name: filename, type: type, size: size, posixDetails: self.posixDetails),
                id: chunk)
        }
        switch receivedId {
        case .outer(let id):
            return FXDirectoryEntryID(
                info: .init(
                    name: filename, type: type, size: size, posixDetails: self.posixDetails), id: id
            )
        case .inner(_):
            fatalError("Multichunk blob cannot be represented with inner id")
        }
    }
}

#if swift(>=5.5) && canImport(_Concurrency)
    extension FXCASBlob: Sendable {}
#endif  // swift(>=5.5) && canImport(_Concurrency)
