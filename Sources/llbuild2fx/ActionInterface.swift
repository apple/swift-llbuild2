// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

/// Interface available to actions during execution.
///
/// Provides typed access to the CAS database and optional tree service.
/// Analogous to ``FXFunctionInterface`` for keys.
public struct FXActionInterface<DataID: FXDataIDProtocol>: Sendable {
    public let _db: any Sendable
    public let treeService: (any FXTypedCASTreeService<DataID>)?

    public init<DB: FXTypedCASDatabase>(db: DB, treeService: (any FXTypedCASTreeService<DataID>)? = nil) where DB.DataID == DataID {
        self._db = db
        self.treeService = treeService
    }
}

extension FXActionInterface where DataID == FXDataID {
    public var db: any FXCASDatabase { self._db as! any FXCASDatabase }
}
