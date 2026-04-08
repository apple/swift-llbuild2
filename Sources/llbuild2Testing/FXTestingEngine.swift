// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXAsyncSupport
import NIOCore
import llbuild2fx

public struct FXTestingEngine {
    private let engine: FXEngine<FXInMemoryCASDatabase>

    public init(
        overrides: [any FXKeyOverrideProtocol] = [],
        resources: [ResourceKey: FXResource] = [:]
    ) {
        let group = FXMakeDefaultDispatchGroup()
        let db = FXInMemoryCASDatabase(group: group)
        let executor = FXLocalExecutor()
        let registry = overrides.isEmpty ? nil : FXKeyOverrideRegistry(overrides)
        self.engine = FXEngine(
            group: group,
            db: db,
            functionCache: nil,
            executor: executor,
            treeService: FXLocalCASTreeService(db: db),
            resources: resources,
            keyOverrides: registry
        )
    }

    public func build<K: FXKey>(key: K, _ ctx: Context) async throws -> K.ValueType
        where K.ValueType.DataID == FXDataID
    {
        return try await engine.build(key: key, ctx).get()
    }
}
