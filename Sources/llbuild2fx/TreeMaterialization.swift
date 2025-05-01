// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSCBasic
import TSCUtility

public protocol FXTreeMaterializer {
    func materialize(tree: FXTreeID) -> AbsolutePath?
}

private class ContextTreeMaterializer {}

extension Context {
    public var fxTreeMaterializer: FXTreeMaterializer? {
        get {
            guard let value = self[ObjectIdentifier(ContextTreeMaterializer.self), as: FXTreeMaterializer.self] else {
                return nil
            }

            return value
        }
        set {
            self[ObjectIdentifier(ContextTreeMaterializer.self)] = newValue
        }
    }
}

public func withTemporaryDirectory<R>(_ ctx: Context, _ body: (AbsolutePath) -> LLBFuture<R>) -> LLBFuture<R> {
    do {
        return try withTemporaryDirectory(removeTreeOnDeinit: false) { path in
            body(path).always { _ in
                _ = try? FileManager.default.removeItem(atPath: path.pathString)
            }
        }
    } catch {
        return ctx.group.next().makeFailedFuture(error)
    }
}

struct UntypedTreeID: FXSingleDataIDValue, FXTreeID {
    let dataID: LLBDataID
}

extension FXFileID {
    public func materialize<R>(filename: String, _ ctx: Context, _ body: @escaping (AbsolutePath) -> LLBFuture<R>) -> LLBFuture<R> {
        load(ctx).flatMap { blob in
            let files: [LLBDirectoryEntryID] = [
                blob.asDirectoryEntry(filename: filename)
            ]

            return LLBCASFileTree.create(files: files, in: ctx.db, ctx)
        }.map { (tree: LLBCASFileTree) in
            UntypedTreeID(dataID: tree.id)
        }.flatMap { treeID in
            treeID.materialize(ctx) { treePath in
                body(treePath.appending(component: filename))
            }
        }
    }
}

extension FXTreeID {
    public func materialize<R>(_ ctx: Context, _ body: @escaping (AbsolutePath) -> LLBFuture<R>) -> LLBFuture<R> {
        if let path = ctx.fxTreeMaterializer?.materialize(tree: self) {
            return body(path)
        }

        return withTemporaryDirectory(ctx) { tmp in
            LLBCASFileTree.export(self.dataID, from: ctx.db, to: tmp, stats: LLBCASFileTree.ExportProgressStatsInt64(), ctx).flatMap {
                body(tmp)
            }
        }
    }
}
