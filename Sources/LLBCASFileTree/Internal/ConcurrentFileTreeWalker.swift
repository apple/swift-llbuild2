// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import TSCBasic
import NIOConcurrencyHelpers

import LLBCAS
import LLBSupport


protocol RetrieveChildrenProtocol: class {
    associatedtype Item

    /// Get the item's children based on the item.
    func children(of: Item) -> LLBFuture<[Item]>
}

/// Walk the hierarchy with bounded concurrency.
final class ConcurrentHierarchyWalker<Item> {

    private let group: LLBFuturesDispatchGroup
    private let futureOpQueue: LLBFutureOperationQueue
    private let getChildren: (_ of: Item) -> LLBFuture<[Item]>

    public init<Delegate: RetrieveChildrenProtocol>(group: LLBFuturesDispatchGroup, delegate: Delegate, maxConcurrentOperations: Int = 100) where Delegate.Item == Item {
        self.group = group
        self.getChildren = {
            delegate.children(of: $0)
        }
        self.futureOpQueue = .init(maxConcurrentOperations: maxConcurrentOperations)
    }

    public func walk(_ item: Item) -> LLBFuture<Void> {
        return futureOpQueue.enqueue(on: group.next()) {
            self.getChildren(item)
        }.flatMap { more in
            let futures = more.map { self.walk($0) }
            return LLBFuture.whenAllSucceed(futures, on: self.group.next()).map { _ in () }
        }
    }
}

class ConcurrentFileTreeWalker: RetrieveChildrenProtocol {
    let db: LLBCASDatabase
    let client: LLBCASFSClient
    let filterCallback: (FilterArgument) -> Bool

    public struct FilterArgument: CustomDebugStringConvertible {
        public let path: AbsolutePath?
        public let type: LLBFileType
        public let size: Int
    }

    public struct Item {
        /// The description of the current CAS filesystem entry.
        let arg: FilterArgument

        /// Used to explode the CAS filesystem further.
        let id: LLBDataID

        /// A reference to a scan result to make scan() function
        /// concurrency-safe (and reentrant, not that we need it).
        let scanResult: ScanResult
    }

    public class ScanResult {
        let lock = NIOConcurrencyHelpers.Lock()
        var collectedArguments = [FilterArgument]()

        public func reapResult() -> [FilterArgument] {
            lock.withLock {
                let result = collectedArguments
                collectedArguments = []
                return result
            }
        }
    }

    public init(db: LLBCASDatabase, _ filter: @escaping (FilterArgument) -> Bool) {
        self.db = db
        self.client = LLBCASFSClient(db)
        self.filterCallback = filter
    }

    /// Concurrently scan the filesystem in CAS, returning the unsorted
    /// list of entries that the filter has accepted.
    /// Scanning a single file will result in a single entry with no name.
    public func scan(root: LLBDataID) -> LLBFuture<[FilterArgument]> {
        let root = Item(arg: FilterArgument(path: .root, type: .UNRECOGNIZED(.min), size: 0), id: root, scanResult: ScanResult())
        let walker = ConcurrentHierarchyWalker(group: db.group, delegate: self)
        return walker.walk(root).map { () in
            root.scanResult.reapResult()
        }
    }

    /// Get the children of a (directory) item.
    public func children(of item: Item) -> LLBFuture<[Item]> {
        let typeHint: LLBFileType?
        switch item.arg.type {
        case .UNRECOGNIZED(.min):
            typeHint = nil
        case let type:
            typeHint = type
        }

        return client.load(item.id, type: typeHint).map { node in
            if typeHint == nil, item.arg.path == .root, item.arg.size == 0 {
                // This is our root. Check if we're allowed to go past it.
                let dirEntry = node.asDirectoryEntry(filename: "-")
                let rootItem = Item(arg: FilterArgument(path: node.tree != nil ? .root : nil, type: dirEntry.info.type, size: Int(clamping: dirEntry.info.size)), id: dirEntry.id, scanResult: item.scanResult)
                guard self.filter(rootItem) else {
                    return []
                }
            }

            switch node.value {
            case let .tree(tree):
                var directories = [Item]()
                for (index, entry) in tree.files.enumerated() {
                    let entryPath = item.arg.path!.appending(component: entry.name)
                    let entryItem = Item(arg: FilterArgument(path: entryPath, type: entry.type, size: Int(clamping: entry.size)), id: tree.object.refs[index], scanResult: item.scanResult)
                    guard self.filter(entryItem) else {
                        continue
                    }

                    if case .directory = entry.type {
                        directories.append(entryItem)
                    }
                }
                return directories
            case let .blob(blob):
                let entryItem = Item(arg: FilterArgument(path: nil, type: blob.type, size: blob.size), id: item.id, scanResult: item.scanResult)
                _ = self.filter(entryItem)
                return []
            }
        }
    }

    private func filter(_ item: Item) -> Bool {

        if case .UNRECOGNIZED(.min) = item.arg.type {
            // We don't expect this to come from the outside of this file.
            // But it is technically possible, so just ignore.
            return false
        }

        guard filterCallback(item.arg) else {
            return false
        }

        item.scanResult.lock.withLock {
            item.scanResult.collectedArguments.append(item.arg)
        }

        return true
    }
}

extension ConcurrentFileTreeWalker.FilterArgument {
    public var debugDescription: String {
        let path = self.path?.pathString ?? "<anonymous file>"
        switch type {
        case .directory where self.path == .root:
            return "\(path)\(size == 0 ? "" : " \(sizeString)")"
        case .directory:
            return "\(path)/\(size == 0 ? "" : " \(sizeString)")"
        case .plainFile:
            return "\(path) \(sizeString)"
        case .executable:
            return "\(path)* \(sizeString)"
        case .symlink:
            return "\(path)@"
        case .UNRECOGNIZED(let code):
            return "\(path)?(\(code))"
        }
    }

    private var sizeString: String {
        if size < 100_000 {
            return "\(size) bytes"
        } else if size < 100_000_000 {
            return String(format: "%.1f MB", Double(size) / 1_000_000)
        } else {
            return String(format: "%.1f GB", Double(size) / 1_000_000_000)
        }
    }
}
