// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import TSCBasic
import llbuild2fx

/// A CAS tree service backed by FXCASFileTree from FXAsyncSupport.
/// Use this in tests and anywhere a simple local tree service is needed.
public struct FXLocalCASTreeService: FXCASTreeService {
    public init() {}

    public func export(_ treeID: FXDataID, from db: FXCASDatabase, to path: AbsolutePath, _ ctx: Context) async throws {
        try await FXCASFileTree.export(treeID, from: db, to: path, stats: FXCASFileTree.ExportProgressStatsInt64(), ctx).get()
    }

    public func importTree(path: AbsolutePath, to db: FXCASDatabase, _ ctx: Context) async throws -> FXDataID {
        return try await FXCASFileTree.import(path: path, to: db, ctx).get()
    }

    public func exportFile(_ fileID: FXDataID, filename: String, from db: FXCASDatabase, to path: AbsolutePath, _ ctx: Context) async throws {
        let client = FXCASFSClient(db)
        let node = try await client.load(fileID, type: .plainFile, ctx).get()
        guard let blob = node.blob else {
            throw FXCASFileTreeFormatError.unexpectedFileData(fileID)
        }
        let entry = blob.asDirectoryEntry(filename: filename)
        let tree = try await FXCASFileTree.create(files: [entry], in: db, ctx).get()
        try await FXCASFileTree.export(tree.id, from: db, to: path, stats: FXCASFileTree.ExportProgressStatsInt64(), ctx).get()
    }
}
