// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore
import TSCBasic

/// Protocol for CAS-backed file tree types.
public protocol FXCASTree: Sendable {
    associatedtype DataID: FXDataIDProtocol = FXDataID
    var id: DataID { get }
}

/// Generic service protocol for CAS tree import/export operations.
/// Clients with custom DataID types implement this directly.
public protocol FXTypedCASTreeService<DataID>: Sendable {
    associatedtype DataID: FXDataIDProtocol

    func export(_ treeID: DataID, to path: AbsolutePath, _ ctx: Context) async throws
    func importTree(path: AbsolutePath, _ ctx: Context) async throws -> DataID
    func exportFile(_ fileID: DataID, filename: String, to path: AbsolutePath, _ ctx: Context) async throws
}


