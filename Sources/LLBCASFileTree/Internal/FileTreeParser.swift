// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic
import ZSTD

import LLBCAS
import LLBSupport


struct CASFileTreeParser {
    let exportPath: AbsolutePath
    let allocator: LLBByteBufferAllocator?

    public init(for exportPath: AbsolutePath, allocator: LLBByteBufferAllocator?) {
        self.exportPath = exportPath
        self.allocator = allocator
    }

    public func parseCASObject(id: LLBDataID, path: AbsolutePath, casObject: LLBCASObject, kind: AnnotatedCASTreeChunk.ItemKind?) throws -> (LLBFilesystemObject, [AnnotatedCASTreeChunk]) {

        switch kind?.type {
        case nil:
            do {
                let info = try LLBFileInfo.deserialize(from: casObject.data)
                return try parseCASObject(id: id, path: path, casObject: casObject, kind: .init(type: info.type))
            } catch {
                throw LLBCASFileTreeFormatError.formatError(reason: "\(id): \(casObject.data.readableBytes) bytes, \(casObject.refs.count) refs, not exportable")
            }
        case .plainFile?, .executable?:
            return try parseFile(id: id, path: path, casObject: casObject, kind: kind!)

        case .directory?:
            return try parseDirectory(id: id, path: path, casObject: casObject)
        case .symlink?:
            guard casObject.refs.isEmpty else {
                throw LLBCASFileTreeFormatError.unexpectedSymlinkData(id)
            }

            // The reference is the symlink target.
            guard let target = casObject.data.getString(at: 0, length: casObject.data.readableBytes) else {
                throw LLBCASFileTreeFormatError.unexpectedSymlinkData(id)
            }

            return (LLBFilesystemObject(path, .symlink(target: target)), [])
        case .UNRECOGNIZED(let typeNumber)?:
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): Unrecognized file type \(typeNumber)")
        }
    }

    private func decompress(compressedData: LLBByteBuffer, kind: AnnotatedCASTreeChunk.ItemKind, debugPath: AbsolutePath) throws -> LLBFastData {
        guard let allocator = self.allocator else {
            throw LLBCASFileTreeFormatError.decompressFailed(path: debugPath)
        }

        let zstd = ZSTDStream()
        try zstd.startDecompression()
        var decompressed = allocator.buffer(capacity: max(3 * (1 + compressedData.readableBytes), Int(clamping: kind.overestimatedSize)))
        var isDone = false
        try compressedData.withUnsafeReadableBytes { ptr in
            _ = try zstd.decompress(input: ptr, into: &decompressed, isDone: &isDone)
        }
        guard isDone else {
            throw LLBCASFileTreeFormatError.decompressFailed(path: debugPath)
        }
        return LLBFastData(decompressed)
    }

    private func parseFile(id: LLBDataID, path: AbsolutePath, casObject: LLBCASObject, kind: AnnotatedCASTreeChunk.ItemKind) throws -> (LLBFilesystemObject, [AnnotatedCASTreeChunk]) {
        let exe: Bool = kind.type == .executable ? true : false

        guard casObject.refs.isEmpty == false else {
            let uncompressed: LLBFastData
            if kind.compressed {
                uncompressed = try decompress(compressedData: casObject.data, kind: kind, debugPath: path)
            } else {
                uncompressed = .init(casObject.data)
            }

            guard let offset = kind.saveOffset else {
                return (LLBFilesystemObject(path, .file(data: uncompressed, executable: exe), permissions: kind.permissions), [])
            }

            return (LLBFilesystemObject(path, .partial(data: uncompressed, offset: offset)), [])
        }

        // Complex file. Parse it.
        let info = try LLBFileInfo.deserialize(from: casObject.data)

        guard info.type == kind.type else {
            // Directory said it is some kind of file but it is not that file.
            throw LLBCASFileTreeFormatError.formatError(reason: "\(relative(path)): inconsistent file type: \(kind.type) -> \(info.type)")
        }

        switch info.payload {
        case let .fixedChunkSize(chunkSize)?:
            let permissions = info.posixPermissions == 0 ? nil : mode_t(clamping: info.posixPermissions)
            let compressed: Bool
            switch info.compression {
            case .none:
                compressed = false
            case .zstd:
                compressed = true
            case .zstdWithDictionary, .UNRECOGNIZED:
                throw LLBCASFileTreeFormatError.formatError(reason: "\(relative(path)): unrecognized compression format")
            }

            guard casObject.refs.count > 1 else {
                let download = AnnotatedCASTreeChunk(casObject.refs[0], path, kind: .init(type: info.type, permissions: permissions, compressed: compressed, saveOffset: kind.saveOffset, overestimatedSize: max(info.size, chunkSize)))
                return (LLBFilesystemObject(), [download])
            }

            // All of the chunks are the same size except the last one.
            // The last one can be any size (0...∞). Therefore we need to
            // ignore the last chunk in size estimation.
            let atLeastSize: UInt64 = chunkSize * UInt64(clamping: casObject.refs.count - 1)
            let atMostSize: UInt64 = chunkSize * UInt64(casObject.refs.count)

            let prepareEmptyFile = LLBFilesystemObject(path, .empty(size: max(info.size, atLeastSize), executable: exe), permissions: permissions)

            let chunks: [AnnotatedCASTreeChunk]
            let eachChunkType = info.type == .executable ? .plainFile : info.type
            chunks = try casObject.refs.enumerated().map { args in
                let (offset, id) = args
                let (saveOffset, overflow) = chunkSize.multipliedReportingOverflow(by: UInt64(offset))
                if overflow || saveOffset > 42_000_000_000_000 {
                    // 42TB single file limit is ought to be enough for anyone.
                    throw LLBCASFileTreeFormatError.fileTooLarge(path: path)
                }
                let overestimatedChunkSize = offset + 1 == casObject.refs.count ? max(info.size, atMostSize) - saveOffset : chunkSize
                let kind = AnnotatedCASTreeChunk.ItemKind(type: eachChunkType, compressed: compressed, saveOffset: saveOffset, overestimatedSize: overestimatedChunkSize)
                return AnnotatedCASTreeChunk(id, path, kind: kind)
            }
            return (prepareEmptyFile, chunks)

        // Detect protocol enhancements at compile time.
        case .inlineChildren?, .referencedChildrenTree?:
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): bad format \(info.payload)")
        case nil:
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): unrecognized format")
        }

    }

    func parseDirectory(id: LLBDataID, path: AbsolutePath, casObject: LLBCASObject) throws -> (LLBFilesystemObject, [AnnotatedCASTreeChunk]) {

        let dirContents: [LLBDirectoryEntry]
        let dirInfo = try LLBFileInfo.deserialize(from: casObject.data)
        guard dirInfo.type == .directory else {
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): object is not a directory")
        }
        guard case let .inlineChildren(children) = dirInfo.payload else {
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): directory doesn't specify children")
        }
        dirContents = children.entries

        if casObject.refs.count < dirContents.count {
            throw LLBCASFileTreeFormatError.unexpectedDirectoryData(id)
        }

        let fsObject = LLBFilesystemObject(path, .directory, permissions: nil)

        let others: [AnnotatedCASTreeChunk]
        others = try zip(casObject.refs, dirContents).map { args in
            let (id, info) = args
            guard info.name != "" && info.name != "." && info.name != ".." && !info.name.contains("/") else {
                throw LLBCASFileTreeFormatError.formatError(reason: "\(String(reflecting: info.name)): unexpected directory entry")
            }

            let kind = AnnotatedCASTreeChunk.ItemKind(type: info.type, overestimatedSize: info.size)
            return AnnotatedCASTreeChunk(id, path.appending(component: info.name), kind: kind)
        }
        return (fsObject, others)
    }

    /// Returns a shorter path suitable for display.
    private func relative(_ path: AbsolutePath) -> String {
        return path.prettyPath(cwd: exportPath)
    }

    /// Returns annotation for an object.
    internal static func getAnnotation(id: LLBDataID, object: LLBCASObject) throws -> AnnotatedCASTreeChunk {
        guard !object.refs.isEmpty else {
            // This is an old-style, compact representation blob.
            return AnnotatedCASTreeChunk(id, .root, kind:
                .init(type: .plainFile,
                        overestimatedSize: UInt64(object.size)))
        }

        let (fsObject, parts) = try Self(for: .root, allocator: nil)
            .parseCASObject(id: id, path: .root, casObject: object, kind: nil)
        switch fsObject.content {
        case .ignore:
            return parts.first!
        case let .empty(size, executable):
            return AnnotatedCASTreeChunk(id, .root, kind:
                .init(type: executable ? .executable: .plainFile,
                        overestimatedSize: size))
        case let .file(data, executable):
            return AnnotatedCASTreeChunk(id, .root, kind:
                .init(type: executable ? .executable: .plainFile,
                        overestimatedSize: UInt64(data.count)))
        case .partial:
            throw LLBCASFileTreeFormatError.formatError(reason: "\(id): Partial data at top level")
        case let .symlink(target):
            return AnnotatedCASTreeChunk(id, .root, kind:
                .init(type: .symlink,
                        overestimatedSize: UInt64(target.count)))
        case .directory:
            return AnnotatedCASTreeChunk(id, .root, kind:
                .init(type: .directory,
                      overestimatedSize: 0))
        }
    }
}

/// A CASFileTree item (DataID) annotated for eventual download and materialization.
/// This chunk represents a whole file or a portion of a file.
struct AnnotatedCASTreeChunk {
    // A pointer to the object to download.
    public let id: LLBDataID

    // The reconstructed file name under which the object has to be known.
    public let path: AbsolutePath

    // We know a little bit about the object behind the given `id`.
    // This helps us parse its contents
    public let kind: ItemKind

    public struct ItemKind {
        public let type: LLBFileType
        public let permissions: mode_t?
        let compressed: Bool
        let saveOffset: UInt64?
        public let overestimatedSize: UInt64

        public init(type: LLBFileType, permissions: mode_t? = nil, compressed: Bool = false, saveOffset: UInt64? = nil, overestimatedSize: UInt64 = 0) {
            self.type = type
            self.permissions = permissions
            self.compressed = compressed
            self.saveOffset = saveOffset
            self.overestimatedSize = overestimatedSize
        }
    }

    public init(_ id: LLBDataID, _ path: AbsolutePath, kind: ItemKind) {
        self.id = id
        self.path = path
        self.kind = kind
    }
}
