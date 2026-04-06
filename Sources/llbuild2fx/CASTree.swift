// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCBasic

/// Protocol for CAS-backed file tree types.
public protocol FXCASTree: Sendable {
    var id: FXDataID { get }
}

/// Service protocol for CAS tree import/export operations.
/// Clients must configure a concrete implementation via `ctx.fxCASTreeService`.
public protocol FXCASTreeService: Sendable {
    func export(_ treeID: FXDataID, from db: FXCASDatabase, to path: AbsolutePath, _ ctx: Context) async throws
    func importTree(path: AbsolutePath, to db: FXCASDatabase, _ ctx: Context) async throws -> FXDataID

    /// Export a single file to `path/filename`. The implementation is responsible for
    /// wrapping the file into a tree if needed for its CAS backend.
    func exportFile(_ fileID: FXDataID, filename: String, from db: FXCASDatabase, to path: AbsolutePath, _ ctx: Context) async throws
}

private class ContextCASTreeService {}

extension Context {
    public var fxCASTreeService: FXCASTreeService? {
        get {
            guard let value = self[ObjectIdentifier(ContextCASTreeService.self), as: FXCASTreeService.self] else {
                return nil
            }
            return value
        }
        set {
            self[ObjectIdentifier(ContextCASTreeService.self)] = newValue
        }
    }
}
