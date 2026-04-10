// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import Dispatch
import FXCore
import Foundation
import NIOCore
import TSCBasic
import TSCUtility

package enum FXCASFileTreeError: Error {
    case inconsistentFileData
    case invalidOrder
    case cannotMergeEmptyList
    case missingObject(FXDataID)
    case notDirectory
}

package struct FXDirectoryEntryID {
    package let info: FXDirectoryEntry
    package let id: FXDataID

    package init(info: FXDirectoryEntry, id: FXDataID) {
        self.info = info
        self.id = id
    }

    package init(_ info: FXDirectoryEntry, _ id: FXDataID) {
        self.info = info
        self.id = id
    }
}

/// A representation of CAS file-system data.
///
/// Each tree currently represents a complete single directory. We may wish to eventually
/// rearrange this implementation to support higher-performance derivative
/// operations (for example, tree union).
package final class FXCASFileTree {
    /// The id of this tree.
    //
    // NOTE: The client typically will have already known this, but recording
    // the `id` here allows us to make some more convenient APIs that don't
    // bother returning the id separately, and the client can still get it if
    // required. In the future we may want to consider dropping this to save space.
    package let id: FXDataID

    /// The handle backing this tree.
    package let object: FXCASObject

    /// Permissions and ownership data.
    package let posixDetails: FXPosixFileDetails?

    /// NOTE: At some point, we may want a way of lazily loading this information.
    package let files: [FXDirectoryEntry]

    package var aggregateSize: Int {
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
    package init(id: FXDataID, object: FXCASObject, at path: AbsolutePath = .root) throws {
        self.id = id
        self.object = object

        let directoryKind = AnnotatedCASTreeChunk.ItemKind(type: .directory, posixDetails: nil)

        let (fsObject, others) = try CASFileTreeParser(for: path, allocator: nil).parseCASObject(
            id: id, path: path, casObject: object, kind: directoryKind)

        guard case .directory = fsObject.content else {
            throw FXCASFileTreeError.inconsistentFileData
        }

        self.posixDetails = fsObject.posixDetails

        self.files = others.map {
            FXDirectoryEntry(
                name: $0.path.basename, type: $0.kind.type,
                size: Int(clamping: $0.kind.overestimatedSize),
                posixDetails: $0.kind.posixDetails.normalized(
                    expectedMode: $0.kind.type.expectedPosixMode, options: nil))
        }

        // Check ordering consistency.
        for i in 0..<max(0, files.count - 1) {
            if files[i].name >= files[i + 1].name {
                throw FXCASFileTreeError.invalidOrder
            }
        }
    }

    /// Create a new tree from the given files, in the provided database.
    ///
    /// NOTE: This is a fairly inefficient method, as it will encode and then
    /// decode redundantly.
    package static func create(
        files inputFiles: [FXDirectoryEntryID],
        in db: any FXCASDatabase,
        posixDetails: FXPosixFileDetails? = nil,
        options: FXCASFileTree.ImportOptions? = nil,
        _ ctx: Context
    ) -> FXFuture<FXCASFileTree> {

        var refs = [FXDataID]()
        var aggregateSize: UInt64 = 0
        var dirEntries = FXDirectoryEntries()
        dirEntries.entries = inputFiles.sorted { $0.info.name < $1.info.name }.map { entry in
            refs.append(entry.id)
            let (partial, overflow) = aggregateSize.addingReportingOverflow(entry.info.size)
            aggregateSize = partial
            // Ignore overflow for now, otherwise.
            assert(!overflow)
            return entry.info
        }

        var dirNode = FXFileInfo()
        dirNode.type = .directory
        dirNode.size = aggregateSize
        dirNode.compression = .none
        dirNode.inlineChildren = dirEntries
        if let pd = posixDetails {
            dirNode.update(posixDetails: pd, options: options)
        }

        do {
            let dirData = try dirNode.serializedData()
            var dirBytes = FXByteBufferAllocator().buffer(capacity: dirData.count)
            dirBytes.writeBytes(dirData)

            // Write the object.
            return db.put(refs: refs, data: dirBytes, ctx).flatMapThrowing { id in
                // FIXME: This does a wasteful redecode of what we just wrote. This
                // API should be fixed. One option would be to change this class so
                // it can directly operate on the encoded representation.
                return try self.init(id: id, object: FXCASObject(refs: refs, data: dirBytes))
            }
        } catch {
            return db.group.next().makeFailedFuture(error)
        }

    }

    /// Try load CASTree from DataID
    package static func load(id: FXDataID, from db: any FXCASDatabase, _ ctx: Context) -> FXFuture<
        FXCASFileTree
    > {
        return db.get(id, ctx).flatMapThrowing { object -> FXCASFileTree in
            guard let object = object else {
                throw FXCASFileTreeError.missingObject(id)
            }
            return try FXCASFileTree(id: id, object: object)
        }
    }

    /// Perform a lookup of a single file.
    package func lookup(_ name: String) -> (id: FXDataID, info: FXDirectoryEntry)? {

        guard name != "." else {
            let entry = FXDirectoryEntry(
                name: ".", type: .directory, size: aggregateSize, posixDetails: self.posixDetails)
            return (id: self.id, info: entry)
        }

        return lookupIndex(name).map { (object.refs[$0], files[$0]) }
    }

    /// Perform a lookup of a single file.
    package func lookupIndex(_ name: String) -> Int? {
        return FXCASFileTree.binarySearch(files) { fileInfo -> Int in
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
    package func merge(with tree: FXCASFileTree, in db: any FXCASDatabase, _ ctx: Context)
        -> FXFuture<FXCASFileTree>
    {
        // Enumerate the LHS and RHS file lists simultaneously.
        var files: [FXDirectoryEntryID] = []
        var futures:
            [FXFuture<
                (
                    index: Int, name: String, result: FXCASFileTree,
                    posixDetails: FXPosixFileDetails?
                )
            >] = []
        for (a, b) in orderedZip(
            zip(self.files, self.object.refs), zip(tree.files, tree.object.refs),
            by: {
                $0.0.name < $1.0.name
            })
        {
            switch (a, b) {
            case (.some(let a), nil):
                files.append(.init(info: a.0, id: a.1))

            case (nil, .some(let b)):
                files.append(.init(info: b.0, id: b.1))

            // If neither side is a directory, then the merge will take the
            // RHS (consistent with copy replacing existing contents).
            case (.some(let a), .some(let b))
            where a.0.type != .directory || b.0.type != .directory:
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
                let aTree = db.get(a.1, ctx).flatMapThrowing { objectOpt -> FXCASFileTree in
                    guard let object = objectOpt else {
                        throw FXCASFileTreeError.missingObject(a.1)
                    }
                    return try FXCASFileTree(id: a.1, object: object)
                }
                let bTree = db.get(b.1, ctx).flatMapThrowing { objectOpt -> FXCASFileTree in
                    guard let object = objectOpt else {
                        throw FXCASFileTreeError.missingObject(b.1)
                    }
                    return try FXCASFileTree(id: b.1, object: object)
                }
                let merged = aTree.and(bTree).flatMap { pair in
                    return pair.0.merge(with: pair.1, in: db, ctx)
                }

                assert(a.0.name == b.0.name)
                let resultIndex = files.count
                futures.append(
                    merged.map {
                        (resultIndex, a.0.name, $0, a.0.hasPosixDetails ? a.0.posixDetails : nil)
                    })
                files.append(
                    .init(
                        info: FXDirectoryEntry(
                            name: b.0.name, type: .directory, size: b.0.size,
                            posixDetails: b.0.posixDetails), id: b.1))

            case (nil, nil):
                fatalError("not possible")
            }
        }

        return FXFuture.whenAllSucceed(futures, on: db.group.next()).flatMap { mergedEntries in
            for (idx, name, result, posixDetails) in mergedEntries {
                files[idx] = .init(
                    info: FXDirectoryEntry(
                        name: name, type: .directory, size: result.aggregateSize,
                        posixDetails: posixDetails), id: result.id)
            }
            return FXCASFileTree.create(files: files, in: db, posixDetails: self.posixDetails, ctx)
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
    package static func merge(trees: [FXCASFileTree], in db: any FXCASDatabase, _ ctx: Context)
        -> FXFuture<FXCASFileTree>
    {
        // Handle degenerate cases.
        guard !trees.isEmpty else {
            return db.group.next().makeFailedFuture(FXCASFileTreeError.cannotMergeEmptyList)
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

    private static func _merge(
        reversedTrees: [FXCASFileTree], in db: any FXCASDatabase, _ ctx: Context
    ) -> FXFuture<FXCASFileTree> {
        assert(reversedTrees.count > 1)

        // Enumerate all trees simultaneously, collecting the merge entries and
        // a list of any future results we will backpatch in.
        let treeFileAndIDPairs = reversedTrees.map { Array(zip($0.files, $0.object.refs)) }
        var futures:
            [FXFuture<
                (
                    index: Int, name: String, result: FXCASFileTree,
                    posixDetails: FXPosixFileDetails?
                )
            >] = []
        var files: [FXDirectoryEntryID] = []
        files.reserveCapacity(treeFileAndIDPairs.count)
        for children in orderedZip(
            sequences: treeFileAndIDPairs,
            by: {
                $0.0.name < $1.0.name
            })
        {
            // Find the first non-nil entry.
            let primary = children.first(where: { $0 != nil })!!

            // If the primary isn't a directory, the merge is simple (it wins over everything else).
            guard primary.0.type == .directory else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Otherwise, we should recursively merge all of the directory trees
            // (and discard anything else).
            let dirOnlyChildren = children.filter { $0?.0.type == .directory }
            assert(!dirOnlyChildren.isEmpty)  // not possible

            // As an optimization, if there is only one child, we don't need to merge.
            guard dirOnlyChildren.count > 1 else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Filter out any redundant directories.
            let uniqueDirOnlyChildren = OrderedSet(
                dirOnlyChildren.map {
                    KeyedPair($0!, key: $0!.1)
                }
            ).map { $0.item }

            // ... and if that resulted in just one directory, we are also done.
            guard uniqueDirOnlyChildren.count > 1 else {
                files.append(.init(info: primary.0, id: primary.1))
                continue
            }

            // Load the trees and dispatch the merge.
            let treesToMerge: [FXFuture<FXCASFileTree>] = uniqueDirOnlyChildren.map { item in
                return db.get(item.1, ctx).flatMapThrowing {
                    guard let object = $0 else { throw FXCASFileTreeError.missingObject(item.1) }
                    return try FXCASFileTree(id: item.1, object: object)
                }
            }
            let merged = FXFuture.whenAllSucceed(treesToMerge, on: db.group.next()).flatMap {
                return _merge(reversedTrees: $0, in: db, ctx)
            }

            // Add a dummy entry to the array and record the merge future.
            let resultIndex = files.count
            futures.append(
                merged.map {
                    (
                        resultIndex, primary.0.name, $0,
                        primary.0.hasPosixDetails ? primary.0.posixDetails : nil
                    )
                })
            files.append(
                .init(info: FXDirectoryEntry(name: "", type: .directory, size: -1), id: primary.1))
        }

        // Wait for all the outstanding submerges.
        return FXFuture.whenAllSucceed(futures, on: db.group.next()).flatMap { mergedEntries in
            for (idx, name, result, posixDetails) in mergedEntries {
                files[idx] = .init(
                    info: FXDirectoryEntry(
                        name: name, type: .directory, size: result.aggregateSize,
                        posixDetails: posixDetails), id: result.id)
            }
            return FXCASFileTree.create(
                files: files, in: db, posixDetails: reversedTrees.first!.posixDetails, ctx)
        }
    }

    /// Perform a lookup of a path.
    ///
    /// - Returns: The entry at the given path, if it exists. If any of the
    ///   intermediate path components do not refer to a directory, a nil result
    ///   is returned.
    package func lookup(path: AbsolutePath, in db: any FXCASDatabase, _ ctx: Context) -> FXFuture<
        (id: FXDataID, info: FXDirectoryEntry)?
    > {
        // Resolve the parent tree.
        var tree: FXFuture<FXCASFileTree?> = db.group.next().makeSucceededFuture(self)
        for component in path.parentDirectory.components.dropFirst() {
            tree = tree.flatMap { tree in
                guard let tree = tree,
                    let result = tree.lookup(component),
                    result.info.type == .directory
                else {
                    return db.group.next().makeSucceededFuture(nil)
                }
                return db.get(result.id, ctx).flatMapThrowing { objectOpt in
                    guard let object = objectOpt else {
                        return nil
                    }
                    return try FXCASFileTree(id: result.id, object: object)
                }
            }
        }

        // Resolve the item.
        if path.isRoot {
            return tree.map { $0?.lookup(".") }
        } else {
            return tree.map { $0?.lookup(path.basename) }
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
    package func merge(
        with tree: FXCASFileTree, in db: any FXCASDatabase, at path: AbsolutePath, _ ctx: Context
    ) -> FXFuture<FXCASFileTree> {
        // Create a new tree with `tree` nested at `path`, then merge.
        var rerootedTree: FXFuture<FXCASFileTree> = db.group.next().makeSucceededFuture(tree)
        for component in path.components.dropFirst().reversed() {
            rerootedTree = rerootedTree.flatMap { tree in
                return FXCASFileTree.create(
                    files: [
                        .init(
                            info: FXDirectoryEntry(
                                name: component, type: .directory, size: tree.aggregateSize,
                                posixDetails: tree.posixDetails),
                            id: tree.id)
                    ], in: db, posixDetails: self.posixDetails, ctx)
            }
        }

        return rerootedTree.flatMap { tree in
            self.merge(with: tree, in: db, ctx)
        }
    }

    package func remove(path: AbsolutePath, in db: any FXCASDatabase, _ ctx: Context) -> FXFuture<
        FXCASFileTree
    > {
        return remove(components: path.components.dropFirst(), in: db, ctx)
    }

    package func remove(components: ArraySlice<String>, in db: any FXCASDatabase, _ ctx: Context)
        -> FXFuture<FXCASFileTree>
    {
        guard !components.isEmpty else {
            return FXCASFileTree.create(files: [], in: db, posixDetails: self.posixDetails, ctx)
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
            let subtree: FXCASFileTree
            do {
                guard let object = objectOpt else {
                    return db.group.next().makeFailedFuture(
                        FXCASFileTreeError.missingObject(subId))
                }
                subtree = try FXCASFileTree(id: subId, object: object)
            } catch {
                return db.group.next().makeFailedFuture(FXCASFileTreeError.notDirectory)
            }
            return subtree.remove(components: components.dropFirst(), in: db, ctx).flatMap {
                newSubtree in
                var newFiles = self.files
                var newRefs = self.object.refs
                newFiles[index].size = .init(clamping: newSubtree.aggregateSize)
                newRefs[index] = newSubtree.id
                return FXCASFileTree.create(
                    files: Array(zip(newFiles, newRefs)).map { .init(info: $0.0, id: $0.1) },
                    in: db, posixDetails: self.posixDetails, ctx)
            }
        }
    }

    // Removes component from the current tree
    package func remove(component: String, in db: any FXCASDatabase, _ ctx: Context) -> FXFuture<
        FXCASFileTree
    > {
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
        return FXCASFileTree.create(
            files: Array(zip(newFiles, newRefs)).map { .init(info: $0.0, id: $0.1) }, in: db,
            posixDetails: self.posixDetails, ctx)
    }

    package func asDirectoryEntry(filename: String) -> FXDirectoryEntryID {
        assert(filename.contains("/") == false)
        let info = FXDirectoryEntry(
            name: filename, type: .directory, size: aggregateSize, posixDetails: self.posixDetails)
        return FXDirectoryEntryID(info, id)
    }
}

#if swift(>=5.5) && canImport(_Concurrency)
    extension FXCASFileTree: Sendable {}
#endif  // swift(>=5.5) && canImport(_Concurrency)
