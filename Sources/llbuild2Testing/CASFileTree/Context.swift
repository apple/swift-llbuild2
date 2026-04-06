// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import TSCUtility

private final class ContextKey {}

/// Support storing and retrieving file tree import options from a context
extension Context {
    package static func with(_ options: FXCASFileTree.ImportOptions) -> Context {
        return Context(
            dictionaryLiteral: (ObjectIdentifier(FXCASFileTree.ImportOptions.self), options as Any)
        )
    }

    package var fileTreeImportOptions: FXCASFileTree.ImportOptions? {
        get {
            guard
                let options = self[
                    ObjectIdentifier(FXCASFileTree.ImportOptions.self),
                    as: FXCASFileTree.ImportOptions.self]
            else {
                return nil
            }

            return options
        }
        set {
            self[ObjectIdentifier(FXCASFileTree.ImportOptions.self)] = newValue
        }
    }
}

/// Support storing and retrieving file tree export storage batcher from a context
extension Context {
    private static let fileTreeExportStorageBatcherKey = ContextKey()

    package var fileTreeExportStorageBatcher: LLBBatchingFutureOperationQueue? {
        get {
            guard
                let options = self[
                    ObjectIdentifier(Self.fileTreeExportStorageBatcherKey),
                    as: LLBBatchingFutureOperationQueue.self]
            else {
                return nil
            }

            return options
        }
        set {
            self[ObjectIdentifier(Self.fileTreeExportStorageBatcherKey)] = newValue
        }
    }
}
