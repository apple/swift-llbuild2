// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOCore
import TSCBasic
import TSCUtility

public protocol FXTreeMaterializer {
    var mountPath: AbsolutePath? { get }

    func materialize(tree: FXTreeID) async throws -> AbsolutePath?
    func materialize(file: FXFileID, filename: String, _ ctx: Context) async throws -> AbsolutePath?
}

extension FXTreeMaterializer {
    public var mountPath: AbsolutePath? {
        return nil
    }
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

public func withTemporaryDirectory<R>(dir: AbsolutePath? = nil, _ ctx: Context, _ body: (AbsolutePath) -> FXFuture<R>) -> FXFuture<R> {
    do {
        return try TSCBasic.withTemporaryDirectory(dir: dir, removeTreeOnDeinit: false) { path in
            body(path).always { _ in
                _ = try? FileManager.default.removeItem(atPath: path.pathString)
            }
        }
    } catch {
        return ctx.group.next().makeFailedFuture(error)
    }
}

public func withTemporaryDirectory<R>(dir: AbsolutePath? = nil, _ ctx: Context, _ body: (AbsolutePath) async throws -> R) async throws -> R {
    return try await TSCBasic.withTemporaryDirectory(dir: dir, removeTreeOnDeinit: true, body)
}

extension FXFileID {
    public func materialize<R>(filename: String, _ ctx: Context, _ body: @escaping (AbsolutePath) -> FXFuture<R>) -> FXFuture<R> {
        return ctx.group.any().makeFutureWithTask {
            try await self.materialize(filename: filename, ctx) { path in
                try await body(path).get()
            }
        }
    }

    public func materialize<R>(filename: String, _ ctx: Context, _ body: (AbsolutePath) async throws -> R) async throws -> R {
        if let dirPath = try await ctx.fxTreeMaterializer?.materialize(file: self, filename: filename, ctx) {
            return try await body(dirPath.appending(component: filename))
        }

        guard let treeService = ctx.fxCASTreeService else {
            throw FXError.missingCASTreeService
        }

        return try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { tmp in
            try await treeService.exportFile(self.dataID, filename: filename, from: ctx.db, to: tmp, ctx)
            return try await body(tmp.appending(component: filename))
        }
    }
}

extension FXTreeID {
    public func materialize<R>(_ ctx: Context, _ body: @escaping (AbsolutePath) -> FXFuture<R>) -> FXFuture<R> {
        return ctx.group.any().makeFutureWithTask {
            try await self.materialize(ctx) { path in
                try await body(path).get()
            }
        }
    }

    public func materialize<R>(_ ctx: Context, _ body: (AbsolutePath) async throws -> R) async throws -> R {
        if let path = try await ctx.fxTreeMaterializer?.materialize(tree: self) {
            return try await body(path)
        }

        guard let treeService = ctx.fxCASTreeService else {
            throw FXError.missingCASTreeService
        }

        return try await TSCBasic.withTemporaryDirectory(removeTreeOnDeinit: true) { tmp in
            try await treeService.export(self.dataID, from: ctx.db, to: tmp, ctx)
            return try await body(tmp)
        }
    }
}
