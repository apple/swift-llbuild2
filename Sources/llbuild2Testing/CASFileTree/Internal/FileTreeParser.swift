// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import Foundation
import TSCBasic

struct CASFileTreeParser {
    let exportPath: AbsolutePath
    let allocator: FXByteBufferAllocator?

    package init(for exportPath: AbsolutePath, allocator: FXByteBufferAllocator?) {
        self.exportPath = exportPath
        self.allocator = allocator
    }

    package func parseCASObject(
        id: FXDataID, path: AbsolutePath, casObject: FXCASObject,
        kind: AnnotatedCASTreeChunk.ItemKind?
    ) throws -> (LLBFilesystemObject, [AnnotatedCASTreeChunk]) {

        switch kind?.type {
        case nil:
            do {
                let info = try FXFileInfo.deserialize(from: casObject.data)
                return try parseCASObject(
                    id: id, path: path, casObject: casObject,
                    kind: .init(type: info.type, posixDetails: .init(from: info)))
            } catch {
                throw FXCASFileTreeFormatError.formatError(
                    reason:
                        "\(id): \(casObject.data.readableBytes) bytes, \(casObject.refs.count) refs, not exportable"
                )
            }
        case .plainFile?, .executable?:
            return try parseFile(id: id, path: path, casObject: casObject, kind: kind!)

        case .directory?:
            return try parseDirectory(id: id, path: path, casObject: casObject)
        case .symlink?:
            guard casObject.refs.isEmpty else {
                throw FXCASFileTreeFormatError.unexpectedSymlinkData(id)
            }

            // The reference is the symlink target.
            guard let target = casObject.data.getString(at: 0, length: casObject.data.readableBytes)
            else {
                throw FXCASFileTreeFormatError.unexpectedSymlinkData(id)
            }

            return (LLBFilesystemObject(path, .symlink(target: target)), [])
        case .UNRECOGNIZED(let typeNumber)?:
            throw FXCASFileTreeFormatError.formatError(
                reason: "\(id): Unrecognized file type \(typeNumber)")
        }
    }

    private func parseFile(
        id: FXDataID, path: AbsolutePath, casObject: FXCASObject,
        kind: AnnotatedCASTreeChunk.ItemKind
    ) throws -> (LLBFilesystemObject, [AnnotatedCASTreeChunk]) {
        let exe: Bool = kind.type == .executable ? true : false

        guard casObject.refs.isEmpty == false else {
            let uncompressed: LLBFastData
            if kind.compressed {
                throw FXCASFileTreeFormatError.decompressFailed("unsupported")
            } else {
                uncompressed = .init(casObject.data)
            }

            guard let offset = kind.saveOffset else {
                return (
                    LLBFilesystemObject(
                        path, .file(data: uncompressed, executable: exe),
                        posixDetails: kind.posixDetails), []
                )
            }

            return (LLBFilesystemObject(path, .partial(data: uncompressed, offset: offset)), [])
        }

        // Complex file. Parse it.
        let info = try FXFileInfo.deserialize(from: casObject.data)

        guard info.type == kind.type else {
            // Directory said it is some kind of file but it is not that file.
            throw FXCASFileTreeFormatError.formatError(
                reason: "\(relative(path)): inconsistent file type: \(kind.type) -> \(info.type)")
        }

        switch info.payload {
        case .fixedChunkSize(let chunkSize)?:
            let compressed: Bool
            switch info.compression {
            case .none:
                compressed = false
            case .UNRECOGNIZED:
                throw FXCASFileTreeFormatError.formatError(
                    reason: "\(relative(path)): unrecognized compression format")
            }

            guard casObject.refs.count > 1 else {
                let download = AnnotatedCASTreeChunk(
                    casObject.refs[0], path,
                    kind: .init(
                        type: info.type, posixDetails: FXPosixFileDetails(from: info),
                        compressed: compressed, saveOffset: kind.saveOffset,
                        overestimatedSize: max(info.size, chunkSize)))
                return (LLBFilesystemObject(), [download])
            }

            // All of the chunks are the same size except the last one.
            // The last one can be any size (0...∞). Therefore we need to
            // ignore the last chunk in size estimation.
            let atLeastSize: UInt64 = chunkSize * UInt64(clamping: casObject.refs.count - 1)
            let atMostSize: UInt64 = chunkSize * UInt64(casObject.refs.count)

            let prepareEmptyFile = LLBFilesystemObject(
                path, .empty(size: max(info.size, atLeastSize), executable: exe),
                posixDetails: FXPosixFileDetails(from: info))

            let chunks: [AnnotatedCASTreeChunk]
            let eachChunkType = info.type == .executable ? .plainFile : info.type
            chunks = try casObject.refs.enumerated().map { args in
                let (offset, id) = args
                let (saveOffset, overflow) = chunkSize.multipliedReportingOverflow(
                    by: UInt64(offset))
                if overflow || saveOffset > 42_000_000_000_000 {
                    // 42TB single file limit is ought to be enough for anyone.
                    throw FXCASFileTreeFormatError.fileTooLarge(path: path)
                }
                let overestimatedChunkSize =
                    offset + 1 == casObject.refs.count
                    ? max(info.size, atMostSize) - saveOffset : chunkSize
                let kind = AnnotatedCASTreeChunk.ItemKind(
                    type: eachChunkType, posixDetails: nil, compressed: compressed,
                    saveOffset: saveOffset, overestimatedSize: overestimatedChunkSize)
                return AnnotatedCASTreeChunk(id, path, kind: kind)
            }
            return (prepareEmptyFile, chunks)

        // Detect protocol enhancements at compile time.
        case .inlineChildren?, .referencedChildrenTree?:
            throw FXCASFileTreeFormatError.formatError(reason: "\(id): bad format")
        case nil:
            throw FXCASFileTreeFormatError.formatError(reason: "\(id): unrecognized format")
        }

    }

    func parseDirectory(id: FXDataID, path: AbsolutePath, casObject: FXCASObject) throws -> (
        LLBFilesystemObject, [AnnotatedCASTreeChunk]
    ) {

        let posixDetails: FXPosixFileDetails?
        let dirContents: [FXDirectoryEntry]
        let dirInfo = try FXFileInfo.deserialize(from: casObject.data)
        guard dirInfo.type == .directory else {
            throw FXCASFileTreeFormatError.formatError(reason: "\(id): object is not a directory")
        }
        guard case .inlineChildren(let children) = dirInfo.payload else {
            throw FXCASFileTreeFormatError.formatError(
                reason: "\(id): directory doesn't specify children")
        }
        dirContents = children.entries
        posixDetails = FXPosixFileDetails(from: dirInfo)

        if casObject.refs.count < dirContents.count {
            throw FXCASFileTreeFormatError.unexpectedDirectoryData(id)
        }

        let fsObject = LLBFilesystemObject(path, .directory, posixDetails: posixDetails)

        let others: [AnnotatedCASTreeChunk]
        others = try zip(casObject.refs, dirContents).map { args in
            let (id, info) = args
            guard
                info.name != "" && info.name != "." && info.name != ".." && !info.name.contains("/")
            else {
                throw FXCASFileTreeFormatError.formatError(
                    reason: "\(String(reflecting: info.name)): unexpected directory entry")
            }

            let kind = AnnotatedCASTreeChunk.ItemKind(
                type: info.type, posixDetails: FXPosixFileDetails(from: info),
                overestimatedSize: info.size)
            return AnnotatedCASTreeChunk(id, path.appending(component: info.name), kind: kind)
        }
        return (fsObject, others)
    }

    /// Returns a shorter path suitable for display.
    private func relative(_ path: AbsolutePath) -> String {
        return path.prettyPath(cwd: exportPath)
    }

    /// Returns annotation for an object.
    internal static func getAnnotation(id: FXDataID, object: FXCASObject) throws
        -> AnnotatedCASTreeChunk
    {
        guard !object.refs.isEmpty else {
            // This is an old-style, compact representation blob.
            return AnnotatedCASTreeChunk(
                id, .root,
                kind:
                    .init(
                        type: .plainFile, posixDetails: nil, overestimatedSize: UInt64(object.size))
            )
        }

        let (fsObject, parts) = try Self(for: .root, allocator: nil)
            .parseCASObject(id: id, path: .root, casObject: object, kind: nil)
        switch fsObject.content {
        case .ignore:
            return parts.first!
        case .empty(let size, let executable):
            return AnnotatedCASTreeChunk(
                id, .root,
                kind:
                    .init(
                        type: executable ? .executable : .plainFile,
                        posixDetails: fsObject.posixDetails, overestimatedSize: size))
        case .file(let data, let executable):
            return AnnotatedCASTreeChunk(
                id, .root,
                kind:
                    .init(
                        type: executable ? .executable : .plainFile,
                        posixDetails: fsObject.posixDetails, overestimatedSize: UInt64(data.count)))
        case .partial:
            throw FXCASFileTreeFormatError.formatError(reason: "\(id): Partial data at top level")
        case .symlink(let target):
            return AnnotatedCASTreeChunk(
                id, .root,
                kind:
                    .init(
                        type: .symlink,
                        posixDetails: fsObject.posixDetails,
                        overestimatedSize: UInt64(target.count)))
        case .directory:
            return AnnotatedCASTreeChunk(
                id, .root,
                kind:
                    .init(
                        type: .directory,
                        posixDetails: fsObject.posixDetails,
                        overestimatedSize: 0))
        }
    }
}

/// A CASFileTree item (DataID) annotated for eventual download and materialization.
/// This chunk represents a whole file or a portion of a file.
struct AnnotatedCASTreeChunk {
    // A pointer to the object to download.
    package let id: FXDataID

    // The reconstructed file name under which the object has to be known.
    package let path: AbsolutePath

    // We know a little bit about the object behind the given `id`.
    // This helps us parse its contents
    package let kind: ItemKind

    package struct ItemKind {
        package let type: FXFileType
        package let posixDetails: FXPosixFileDetails
        let compressed: Bool
        let saveOffset: UInt64?
        package let overestimatedSize: UInt64

        package init(
            type: FXFileType, posixDetails: FXPosixFileDetails?, compressed: Bool = false,
            saveOffset: UInt64? = nil, overestimatedSize: UInt64 = 0
        ) {
            self.type = type
            self.compressed = compressed
            self.saveOffset = saveOffset
            self.overestimatedSize = overestimatedSize
            self.posixDetails = posixDetails ?? FXPosixFileDetails()
        }
    }

    package init(_ id: FXDataID, _ path: AbsolutePath, kind: ItemKind) {
        self.id = id
        self.path = path
        self.kind = kind
    }
}
