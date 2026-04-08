// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

public struct FXDiagnostics<DataID: FXDataIDProtocol>: FXThinEncodedSingleDataIDValue, FXTreeID {
    public let dataID: DataID
    public init(dataID: DataID) {
        self.dataID = dataID
    }
}

public protocol FXDiagnosticsGathering<DataID>: Sendable {
    associatedtype DataID: FXDataIDProtocol = FXDataID
    func gatherDiagnostics(pid: Int32?, _ ctx: Context) async throws -> FXDiagnostics<DataID>
}
