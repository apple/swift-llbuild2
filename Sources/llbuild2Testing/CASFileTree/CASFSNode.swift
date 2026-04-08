// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import FXCore
import Foundation

/// A CAS object (can be tree or blob)
package struct FXCASFSNode {
    package enum Error: Swift.Error {
        case notApplicable
    }

    package enum NodeContent: Sendable {
        case tree(FXCASFileTree)
        case blob(FXCASBlob)
    }

    package let db: any FXCASDatabase
    package let value: NodeContent

    package init(tree: FXCASFileTree, db: any FXCASDatabase) {
        self.db = db
        self.value = NodeContent.tree(tree)
    }

    package init(blob: FXCASBlob, db: any FXCASDatabase) {
        self.db = db
        self.value = NodeContent.blob(blob)
    }

    /// Returns aggregated (for trees) or regular size of the Entry
    package func size() -> Int {
        switch value {
        case .tree(let tree):
            return tree.aggregateSize
        case .blob(let blob):
            return blob.size
        }
    }

    /// Gives CASFSNode type (meaningful for files)
    package func type() -> LLBFileType {
        switch value {
        case .tree(_):
            return .directory
        case .blob(let blob):
            return blob.type
        }
    }

    /// Optionally chainable tree access
    package var tree: FXCASFileTree? {
        guard case .tree(let tree) = value else {
            return nil
        }
        return tree
    }

    /// Optionally chainable blob access
    package var blob: FXCASBlob? {
        guard case .blob(let blob) = value else {
            return nil
        }
        return blob
    }

    package func asDirectoryEntry(filename: String) -> LLBDirectoryEntryID {
        switch value {
        case .tree(let tree):
            return tree.asDirectoryEntry(filename: filename)
        case .blob(let blob):
            return blob.asDirectoryEntry(filename: filename)
        }
    }
}

#if swift(>=5.5) && canImport(_Concurrency)
    extension FXCASFSNode: Sendable {}
#endif  // swift(>=5.5) && canImport(_Concurrency)
