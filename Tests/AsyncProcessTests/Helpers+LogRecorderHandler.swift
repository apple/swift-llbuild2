//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Logging
import NIOConcurrencyHelpers

final internal class LogRecorderHandler: LogHandler {
    internal let state = NIOLockedValueBox<State>(State())

    struct FullLogMessage: Equatable {
        var level: Logger.Level
        var message: Logger.Message
        var metadata: Logger.Metadata
    }

    struct State {
        var metadata: [String: Logger.Metadata.Value] = [:]
        var messages: [FullLogMessage] = []
        var logLevel: Logger.Level = .trace
    }

    func makeLogger() -> Logger {
        return Logger(label: "LogRecorder for tests", factory: { _ in self })
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let fullMessage = FullLogMessage(
            level: level,
            message: message,
            metadata: self.metadata.merging(metadata ?? [:]) { l, r in r }
        )
        self.state.withLockedValue { state in
            state.messages.append(fullMessage)
        }
    }

    var recordedMessages: [FullLogMessage] {
        return self.state.withLockedValue { $0.messages }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get {
            return self.state.withLockedValue {
                $0.metadata[key]
            }
        }
        set {
            self.state.withLockedValue {
                $0.metadata[key] = newValue
            }
        }
    }

    var metadata: Logging.Logger.Metadata {
        get {
            return self.state.withLockedValue {
                $0.metadata
            }
        }

        set {
            return self.state.withLockedValue {
                $0.metadata = newValue
            }
        }
    }

    var logLevel: Logging.Logger.Level {
        get {
            return self.state.withLockedValue {
                $0.logLevel
            }
        }

        set {
            return self.state.withLockedValue {
                $0.logLevel = newValue
            }
        }
    }
}
