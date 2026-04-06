// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import TSCUtility

/// A simple in-memory implementation of the `FXCASDatabase` protocol.
package final class FXInMemoryCASDatabase: Sendable {
    struct State: Sendable {
        /// The content.
        var content = [FXDataID: FXCASObject]()

        var totalDataBytes: Int = 0
    }

    private let state: NIOLockedValueBox<State> = NIOLockedValueBox(State())

    /// Threads capable of running futures.
    package let group: FXFuturesDispatchGroup

    /// The total number of data bytes in the database (this does not include the size of refs).
    package var totalDataBytes: Int {
        return self.state.withLockedValue { state in
            return state.totalDataBytes
        }
    }

    /// Create an in-memory database.
    package init(group: FXFuturesDispatchGroup) {
        self.group = group
    }

    /// Delete the data in the database.
    /// Intentionally not exposed via the CASDatabase protocol.
    package func delete(_ id: FXDataID, recursive: Bool) -> FXFuture<Void> {
        self.state.withLockedValue { state in
            unsafeDelete(state: &state, id, recursive: recursive)
        }
        return group.next().makeSucceededFuture(())
    }
    private func unsafeDelete(state: inout State, _ id: FXDataID, recursive: Bool) {
        guard let object = state.content[id] else {
            return
        }
        state.totalDataBytes -= object.data.readableBytes

        guard recursive else {
            return
        }

        for ref in object.refs {
            unsafeDelete(state: &state, ref, recursive: recursive)
        }
    }
}

extension FXInMemoryCASDatabase: FXCASDatabase {
    package func supportedFeatures() -> FXFuture<FXCASFeatures> {
        return group.next().makeSucceededFuture(FXCASFeatures(preservesIDs: true))
    }

    package func contains(_ id: FXDataID, _ ctx: Context) -> FXFuture<Bool> {
        let result = self.state.withLockedValue { state in
            state.content.index(forKey: id) != nil
        }
        return group.next().makeSucceededFuture(result)
    }

    package func get(_ id: FXDataID, _ ctx: Context) -> FXFuture<FXCASObject?> {
        let result = self.state.withLockedValue { state in state.content[id] }
        return group.next().makeSucceededFuture(result)
    }

    package func identify(refs: [FXDataID] = [], data: FXByteBuffer, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        return group.next().makeSucceededFuture(FXDataID(blake3hash: data, refs: refs))
    }

    package func put(refs: [FXDataID] = [], data: FXByteBuffer, _ ctx: Context) -> FXFuture<
        FXDataID
    > {
        return put(knownID: FXDataID(blake3hash: data, refs: refs), refs: refs, data: data, ctx)
    }

    package func put(
        knownID id: FXDataID, refs: [FXDataID] = [], data: FXByteBuffer, _ ctx: Context
    ) -> FXFuture<FXDataID> {
        self.state.withLockedValue { state in
            guard state.content[id] == nil else {
                assert(state.content[id]?.data == data, "put data for id doesn't match")
                return
            }
            state.totalDataBytes += data.readableBytes
            state.content[id] = FXCASObject(refs: refs, data: data)
        }
        return group.next().makeSucceededFuture(id)
    }
}

package struct FXInMemoryCASDatabaseScheme: FXCASDatabaseScheme {
    package static let scheme = "mem"

    package static func isValid(host: String?, port: Int?, path: String, query: String?) -> Bool {
        return host == nil && port == nil && path == "" && query == nil
    }

    package static func open(group: FXFuturesDispatchGroup, url: Foundation.URL) throws
        -> any FXCASDatabase
    {
        return FXInMemoryCASDatabase(group: group)
    }
}
