// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import Logging

/// Support protocol for recording events during FXKey evaluations
public protocol FXMetricsSink {
    func event(
        _ message: Logger.Message,
        metadata: @autoclosure () -> Logger.Metadata,
        _ ctx: Context,
        file: String,
        function: String,
        line: UInt
    )
}

extension FXMetricsSink {
    public func event(
        _ message: Logger.Message,
        metadata: @autoclosure () -> Logger.Metadata = [:],
        _ ctx: Context = .init(),
        file_ file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        self.event(message, metadata: metadata(), ctx, file: file, function: function, line: line)
    }
}

/// Protocol for streaming log messages during FXAction evaluations. (Useful for capturing the output of spawned processes while they're still running.)
public protocol StreamingLogHandler {
    func streamLog(spec: ProcessSpec, channel: String, _ data: LLBByteBuffer) async throws
}

// Support storing and retrieving logger, metrics, and file handle generator instances from a Context.
extension Context {
    public var logger: Logger? {
        get {
            return self[ObjectIdentifier(Logger.self), as: Logger.self]
        }
        set {
            self[ObjectIdentifier(Logger.self)] = newValue
        }
    }

    public var metrics: FXMetricsSink? {
        get {
            return self[ObjectIdentifier(FXMetricsSink.self), as: FXMetricsSink.self]
        }
        set {
            self[ObjectIdentifier(FXMetricsSink.self)] = newValue
        }
    }

    public var streamingLogHandler: StreamingLogHandler? {
        get { self[ObjectIdentifier(StreamingLogHandler.self)] }
        set { self[ObjectIdentifier(StreamingLogHandler.self)] = newValue }
    }
}
