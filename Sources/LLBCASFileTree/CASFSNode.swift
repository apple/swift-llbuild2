// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import LLBCAS


/// A CAS object (can be tree or blob)
public struct LLBCASFSNode {
    public enum Error: Swift.Error {
        case notApplicable
    }

    public enum NodeContent {
        case tree(LLBCASFileTree)
        case blob(LLBCASBlob)
    }

    public let db: LLBCASDatabase
    public let value: NodeContent

    public init(tree: LLBCASFileTree, db: LLBCASDatabase) {
        self.db = db
        self.value = NodeContent.tree(tree)
    }

    public init(blob: LLBCASBlob, db: LLBCASDatabase) {
        self.db = db
        self.value = NodeContent.blob(blob)
    }

    /// Returns aggregated (for trees) or regular size of the Entry
    public func size() -> Int {
        switch value {
        case .tree(let tree):
            return tree.aggregateSize
        case .blob(let blob):
            return blob.size
        }
    }

    /// Gives CASFSNode type (meaningful for files)
    public func type() -> LLBFileType {
        switch value {
        case .tree(_):
            return .directory
        case .blob(let blob):
            return blob.type
        }
    }

    /// Optionally chainable tree access
    public var tree: LLBCASFileTree? {
        guard case .tree(let tree) = value else {
            return nil
        }
        return tree
    }

    /// Optionally chainable blob access
    public var blob: LLBCASBlob? {
        guard case .blob(let blob) = value else {
            return nil
        }
        return blob
    }

    public func asDirectoryEntry(filename: String) -> LLBDirectoryEntryID {
        switch value {
        case let .tree(tree):
            return tree.asDirectoryEntry(filename: filename)
        case let .blob(blob):
            return blob.asDirectoryEntry(filename: filename)
        }
    }
}
