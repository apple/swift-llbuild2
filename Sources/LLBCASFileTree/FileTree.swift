// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Dispatch
import Foundation

import TSCBasic
import TSCUtility

import LLBCAS
import LLBSupport


public enum LLBCASFileTreeError: Error {
    case inconsistentFileData
    case invalidOrder
    case cannotMergeEmptyList
    case missingObject(LLBDataID)
    case notDirectory
}

public struct LLBDirectoryEntryID {
    public let info: LLBDirectoryEntry
    public let id: LLBDataID

    public init(info: LLBDirectoryEntry, id: LLBDataID) {
        self.info = info
        self.id = id
    }

    public init(_ info: LLBDirectoryEntry, _ id: LLBDataID) {
        self.info = info
        self.id = id
    }
}

/// A representation of CAS file-system data.
///
/// Each tree currently represents a complete single directory. We may wish to eventually
/// rearrange this implementation to support higher-performance derivative
/// operations (for example, tree union).
public final class LLBCASFileTree {
    /// The id of this tree.
    //
    // NOTE: The client typically will have already known this, but recording
    // the `id` here allows us to make some more convenient APIs that don't
    // bother returning the id separately, and the client can still get it if
    // required. In the future we may want to consider dropping this to save space.
    public let id: LLBDataID

    /// The handle backing this tree.
    public let object: LLBCASObject

    /// NOTE: At some point, we may want a way of lazily loading this information.
    public let files: [LLBDirectoryEntry]

    public var aggregateSize: Int {
        return Int(clamping: files.reduce(0) { $0 + $1.size })
    }

    /// Create a CASTree that will be decoded from the given object.
    ///
    /// This method does no recursive validation, so accessors may throw
    /// if the subobjects later appears to not be a tree with a valid encoding.
    ///
    /// - Parameters:
    ///   - id: The id for the tree.
    ///   - object: The object backing this tree.
    ///   - at path: The logical path that leads to this tree.
    public init(id: LLBDataID, object: LLBCASObject, at path: AbsolutePath = .init("/")) throws {
        self.id = id
        self.object = object

        let directoryKind = AnnotatedCASTreeChunk.ItemKind(type: .directory)

        let (fsObject, others) = try CASFileTreeParser(for: path, allocator: nil).parseCASObject(id: id, path: path, casObject: object, kind: directoryKind)

        guard case .directory = fsObject.content else {
            throw LLBCASFileTreeError.inconsistentFileData
        }

        self.files = others.map {
            LLBDirectoryEntry(name: $0.path.basename, type: $0.kind.type, size: Int(clamping: $0.kind.overestimatedSize))
        }

        // Check ordering consistency.
        for i in 0 ..< max(0, files.count - 1) {
            if files[i].name >= files[i + 1].name {
                throw LLBCASFileTreeError.invalidOrder
            }
        }
    }

    /// Create a new tree from the given files, in the provided database.
    ///
    /// NOTE: This is a fairly inefficient method, as it will encode and then
    /// decode redundantly.
    public static func create(
        files inputFiles: [LLBDirectoryEntryID],
        in db: LLBCASDatabase,
        _ ctx: Context
    ) -> LLBFuture<LLBCASFileTree> {

        var refs = [LLBDataID]()
        var aggregateSize: UInt64 = 0
        var dirEntries = LLBDirectoryEntries()
        dirEntries.entries = inputFiles.sorted{ $0.info.name < $1.info.name }.map { entry in
            refs.append(entry.id)
            let (partial, overflow) = aggregateSize.addingReportingOverflow(entry.info.size)
            aggregateSize = partial
            // Ignore overflow for now, otherwise.
            assert(!overflow)
            return entry.info
        }

        var dirNode = LLBFileInfo()
        dirNode.type = .directory
        dirNode.size = aggregateSize
        dirNode.compression = .none
        dirNode.inlineChildren = dirEntries

        do {
            let dirData = try dirNode.serializedData()
            var dirBytes = LLBByteBufferAllocator().buffer(capacity: dirData.count)
            dirBytes.writeBytes(dirData)

            // Write the object.
            return db.put(refs: refs, data: dirBytes, ctx).flatMapThrowing { id in
                // FIXME: This does a wasteful redecode of what we just wrote. This
                // API should be fixed. One option would be to change this class so
                // it can directly operate on the encoded representation.
                return try self.init(id: id, object: LLBCASObject(refs: refs, data: dirBytes))
            }
        } catch {
            return db.group.next().makeFailedFuture(error)
        }

    }

    /// Try load CASTree from DataID
    public static func load(id: LLBDataID, from db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        return db.get(id, ctx).flatMapThrowing { object -> LLBCASFileTree in
            guard let object = object else {
                throw LLBCASFileTreeError.missingObject(id)
            }
            return try LLBCASFileTree(id: id, object: object)
        }
    }

    /// Perform a lookup of a single file.
    public func lookup(_ name: String) -> (id: LLBDataID, info: LLBDirectoryEntry)? {

        guard name != "." else {
            let entry = LLBDirectoryEntry(name: ".", type: .directory, size: aggregateSize)
            return (id: self.id, info: entry)
        }

        return lookupIndex(name).map{ (object.refs[$0], files[$0]) }
    }

    /// Perform a lookup of a single file.
    public func lookupIndex(_ name: String) -> Int? {
        return LLBCASFileTree.binarySearch(files) { fileInfo -> Int in
                guard name <= fileInfo.name else {
                    return 1
                }
                guard name == fileInfo.name else {
                    return -1
                }
                return 0
            }
    }

    /// Create a union of two trees.
    ///
    /// In the case of duplicates, the entries from the input `tree` will be
    /// taken. In other words, this operation behaves semantically similar to
    ///    ```
    ///    cp -r tree/* .
    ///    ```
    /// operated within the tree defined by `self`.
    ///
    /// - Parameters:
    ///   - tree: The tree to merge with.
    ///   - db: The database to create any new objects in.
    public func merge(with tree: LLBCASFileTree, in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        // Enumerate the LHS and RHS file lists simultaneously.
        var files: [LLBDirectoryEntryID] = []
        var futures: [LLBFuture<(index: Int, name: String, result: LLBCASFileTree)>] = []
        for (a, b) in orderedZip(zip(self.files, self.object.refs), zip(tree.files, tree.object.refs), by: {
                    $0.0.name < $1.0.name
                }) {
            switch (a, b) {
            case (.some(let a), nil):
                files.append(.init(info: a.0, id: a.1))

            case (nil, .some(let b)):
                files.append(.init(info: b.0, id: b.1))

                // If neither side is a directory, then the merge will take the
                // RHS (consistent with copy replacing existing contents).
            case (.some(let a), .some(let b)) where a.0.type != .directory || b.0.type != .directory:
                // If neither side is a directory, then we always take the RHS.
                files.append(.init(info: b.0, id: b.1))

                // Otherwise, a merge of directories is needed.
            case (.some(let a), .some(let b)):
                assert(a.0.type == .directory && b.0.type == .directory)

                // As an optimization, if the LHS and RHS are identical, no step
                // needs to be taken.
                if a.1 == b.1 {
                    files.append(.init(info: b.0, id: b.1))
                    break
                }

                // Wneed to merge recursively; we add a dummy entry to the
                // array and record a future.
                let aTree = db.get(a.1, ctx).flatMapThrowing { objectOpt -> LLBCASFileTree in
                    guard let object = objectOpt else {
                        throw LLBCASFileTreeError.missingObject(a.1)
                    }
                    return try LLBCASFileTree(id: a.1, object: object)
                }
                let bTree = db.get(b.1, ctx).flatMapThrowing { objectOpt -> LLBCASFileTree in
                    guard let object = objectOpt else {
                        throw LLBCASFileTreeError.missingObject(b.1)
                    }
                    return try LLBCASFileTree(id: b.1, object: object)
                }
                let merged = aTree.and(bTree).flatMap { pair in
                    return pair.0.merge(with: pair.1, in: db, ctx)
                }

                assert(a.0.name == b.0.name)
                let resultIndex = files.count
                futures.append(merged.map{ (resultIndex, a.0.name, $0) })
                files.append(.init(info: LLBDirectoryEntry(name: b.0.name, type: .directory, size: b.0.size), id: b.1))

            case (nil, nil):
                fatalError("not possible")
            }
        }

        return LLBFuture.whenAllSucceed(futures, on: db.group.next()).flatMap { mergedEntries in
            for (idx, name, result) in mergedEntries {
                files[idx] = .init(info: LLBDirectoryEntry(name: name, type: .directory, size: result.aggregateSize), id: result.id)
            }
            return LLBCASFileTree.create(files: files, in: db, ctx)
        }
    }

    /// Create a union of N trees.
    ///
    /// In the case of duplicates, the entries from the *last* `tree` in the list will be
    /// taken. In other words, this operation behaves semantically similar to
    ///    ```
    ///    for tree in trees; do cp -r tree .; done
    ///    ```
    ///
    /// - Parameters:
    ///   - trees: The trees to merge.
    ///   - db: The database to create any new objects in.
    public static func merge(trees: [LLBCASFileTree], in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        // Handle degenerate cases.
        guard !trees.isEmpty else {
            return db.group.next().makeFailedFuture(LLBCASFileTreeError.cannotMergeEmptyList)
        }
        guard trees.count > 1 else {
            return db.group.next().makeSucceededFuture(trees[0])
        }

        // NOTE: We intentionally reverse the order of the trees here so that
        // the core algorithm can walk from the beginning of each "row", while
        // preserving the semantics of the later trees in the list overriding
        // content from earlier ones (in keeping with the published semantics).
        return _merge(reversedTrees: trees.reversed(), in: db, ctx)
    }

    private static func _merge(reversedTrees: [LLBCASFileTree], in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        assert(reversedTrees.count > 1)

        // Enumerate all trees simultaneously, collecting the merge entries and
        // a list of any future results we will backpatch in.
        let treeFileAndIDPairs = reversedTrees.map{ Array(zip($0.files, $0.object.refs)) }
        var futures: [LLBFuture<(index: Int, name: String, result: LLBCASFileTree)>] = []
        var files: [LLBDirectoryEntryID] = []
        files.reserveCapacity(treeFileAndIDPairs.count)
        for children in orderedZip(sequences: treeFileAndIDPairs, by: {
                    $0.0.name < $1.0.name
                }) {
            // Find the first non-nil entry.
            let primary = children.first(where: { $0 != nil })!!

            // If the primary isn't a directory, the merge is simple (it wins over everything else).
            guard primary.0.type == .directory else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Otherwise, we should recursively merge all of the directory trees
            // (and discard anything else).
            let dirOnlyChildren = children.filter{ $0?.0.type == .directory }
            assert(!dirOnlyChildren.isEmpty) // not possible

            // As an optimization, if there is only one child, we don't need to merge.
            guard dirOnlyChildren.count > 1 else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Filter out any redundant directories.
            let uniqueDirOnlyChildren = OrderedSet(dirOnlyChildren.map {
                    KeyedPair($0!, key: $0!.1)
                }).map{ $0.item }

            // ... and if that resulted in just one directory, we are also done.
            guard uniqueDirOnlyChildren.count > 1 else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Load the trees and dispatch the merge.
            let treesToMerge: [LLBFuture<LLBCASFileTree>] = uniqueDirOnlyChildren.map { item in
                return db.get(item.1, ctx).flatMapThrowing {
                    guard let object = $0 else { throw LLBCASFileTreeError.missingObject(item.1) }
                    return try LLBCASFileTree(id: item.1, object: object)
                }
            }
            let merged = LLBFuture.whenAllSucceed(treesToMerge, on: db.group.next()).flatMap {
                return _merge(reversedTrees: $0, in: db, ctx)
            }

            // Add a dummy entry to the array and record the merge future.
            let resultIndex = files.count
            futures.append(merged.map{ (resultIndex, primary.0.name, $0) })
            files.append(.init(info: LLBDirectoryEntry(name: "", type: .directory, size: -1), id: primary.1))
        }

        // Wait for all the outstanding submerges.
        return LLBFuture.whenAllSucceed(futures, on: db.group.next()).flatMap { mergedEntries in
            for (idx, name, result) in mergedEntries {
                files[idx] = .init(info: LLBDirectoryEntry(name: name, type: .directory, size: result.aggregateSize), id: result.id)
            }
            return LLBCASFileTree.create(files: files, in: db, ctx)
        }
    }

    /// Perform a lookup of a path.
    ///
    /// - Returns: The entry at the given path, if it exists. If any of the
    ///   intermediate path components do not refer to a directory, a nil result
    ///   is returned.
    public func lookup(path: AbsolutePath, in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<(id: LLBDataID, info: LLBDirectoryEntry)?> {
        // Resolve the parent tree.
        var tree: LLBFuture<LLBCASFileTree?> = db.group.next().makeSucceededFuture(self)
        for component in path.parentDirectory.components.dropFirst() {
            tree = tree.flatMap { tree in
                guard let tree = tree,
                      let result = tree.lookup(component),
                      result.info.type == .directory else {
                    return db.group.next().makeSucceededFuture(nil)
                }
                return db.get(result.id, ctx).flatMapThrowing { objectOpt in
                    guard let object = objectOpt else {
                        return nil
                    }
                    return try LLBCASFileTree(id: result.id, object: object)
                }
            }
        }

        // Resolve the item.
        if path.isRoot {
            return tree.map{ $0?.lookup(".") }
        } else {
            return tree.map{ $0?.lookup(path.basename) }
        }
    }

    /// Create a union of two trees by merging the input `tree` at `path`.
    ///
    /// In the case of duplicates, the entries from the input `tree` will be
    /// taken. In other words, this operation behaves semantically similar to
    ///    ```
    ///    cp -r tree/* path
    ///    ```
    /// operated within the tree defined by `self`.
    ///
    /// - Parameters:
    ///   - tree: The tree to merge with.
    ///   - db: The database to create any new objects in.
    ///   - path: The path within `self` to merge `tree` at. This will be
    ///     created, if it does not exist. Any existing non-directory traversed
    ///     by `path` will be replaced with a directory, if necessary.
    public func merge(
        with tree: LLBCASFileTree, in db: LLBCASDatabase, at path: AbsolutePath, _ ctx: Context
    ) -> LLBFuture<LLBCASFileTree> {
        // Create a new tree with `tree` nested at `path`, then merge.
        var rerootedTree: LLBFuture<LLBCASFileTree> = db.group.next().makeSucceededFuture(tree)
        for component in path.components.dropFirst().reversed() {
            rerootedTree = rerootedTree.flatMap { tree in
                return LLBCASFileTree.create(files: [
                    .init(info: LLBDirectoryEntry(name: component, type: .directory, size: tree.aggregateSize),
                          id: tree.id)], in: db, ctx)
            }
        }

        return rerootedTree.flatMap { tree in
            self.merge(with: tree, in: db, ctx)
        }
    }

    public func remove(path: AbsolutePath, in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        return remove(components: path.components.dropFirst(), in: db, ctx)
    }

    public func remove(components: ArraySlice<String>, in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        guard !components.isEmpty else {
            return LLBCASFileTree.create(files: [], in: db, ctx)
        }
        guard components.count > 1 else {
            return remove(component: components.first!, in: db, ctx)
        }
        let indexOpt = lookupIndex(components.first!)
        guard let index = indexOpt else {
            return db.group.next().makeSucceededFuture(self)
        }
        // Go deeper and recreate this tree
        let subId = object.refs[index]
        return db.get(subId, ctx).flatMap { objectOpt in
            let subtree: LLBCASFileTree
            do {
                guard let object = objectOpt else {
                    return db.group.next().makeFailedFuture(LLBCASFileTreeError.missingObject(subId))
                }
                subtree = try LLBCASFileTree(id: subId, object: object)
            } catch {
                return db.group.next().makeFailedFuture(LLBCASFileTreeError.notDirectory)
            }
            return subtree.remove(components: components.dropFirst(), in: db, ctx).flatMap { newSubtree in
                var newFiles = self.files
                var newRefs = self.object.refs
                newFiles[index].size = .init(clamping: newSubtree.aggregateSize)
                newRefs[index] = newSubtree.id
                return LLBCASFileTree.create(files: Array(zip(newFiles, newRefs)).map { .init(info: $0.0, id: $0.1) }, in: db, ctx)
            }
        }
    }

    // Removes component from the current tree
    public func remove(component: String, in db: LLBCASDatabase, _ ctx: Context) -> LLBFuture<LLBCASFileTree> {
        let indexOpt = lookupIndex(component)
        guard let index = indexOpt else {
            // No modifications
            return db.group.next().makeSucceededFuture(self)
        }
        // Create new tree without component to remove
        var newFiles = files
        var newRefs = object.refs
        newFiles.remove(at: index)
        newRefs.remove(at: index)
        return LLBCASFileTree.create(files: Array(zip(newFiles, newRefs)).map { .init(info: $0.0, id: $0.1) }, in: db, ctx)
    }

    public func asDirectoryEntry(filename: String) -> LLBDirectoryEntryID {
        assert(filename.contains("/") == false)
        let info = LLBDirectoryEntry(name: filename, type: .directory, size: aggregateSize)
        return LLBDirectoryEntryID(info, id)
    }
}
