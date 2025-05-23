// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

public struct FXDiagnostics: FXThinEncodedSingleDataIDValue, FXTreeID {
    public let dataID: LLBDataID
    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}

public protocol FXDiagnosticsGathering: Sendable {
    func gatherDiagnostics(pid: Int32?, _ ctx: Context) -> LLBFuture<FXDiagnostics>
}

private final class ContextDiagnosticsGatherer: Sendable {}

extension Context {
    public var fxDiagnosticsGatherer: FXDiagnosticsGathering? {
        get {
            guard let value = self[ObjectIdentifier(ContextDiagnosticsGatherer.self), as: FXDiagnosticsGathering.self] else {
                return nil
            }

            return value
        }
        set {
            self[ObjectIdentifier(ContextDiagnosticsGatherer.self)] = newValue
        }
    }
}
