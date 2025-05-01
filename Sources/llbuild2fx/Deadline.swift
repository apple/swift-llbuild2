// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIO
import TSCUtility
import TSFFutures

private class DeadlineKey {}

extension Context {
    public var fxDeadline: Date? {
        get {
            self[ObjectIdentifier(DeadlineKey.self), as: Date.self]
        }
        set {
            self[ObjectIdentifier(DeadlineKey.self)] = newValue
        }
    }

    public var nioDeadline: NIODeadline? {
        guard let foundationDeadline = fxDeadline else {
            return nil
        }

        guard foundationDeadline != .distantFuture else {
            return nil
        }

        let then = NIODeadline.now()
        let now = Date()
        let timeLeft: TimeInterval = foundationDeadline.timeIntervalSince(now)
        let milliseconds = timeLeft * 1000
        let microseconds = milliseconds * 1000
        let nanoseconds = Int64(microseconds * 1000)
        return then + TimeAmount.nanoseconds(nanoseconds)
    }

    public func fxReducingDeadline(to atLeast: Date) -> Self {
        var ctx = self

        if let existing = fxDeadline {
            if existing > atLeast {
                ctx.fxDeadline = atLeast
            }
        } else {
            ctx.fxDeadline = atLeast
        }

        return ctx
    }

    public func fxApplyDeadline<T>(_ cancellable: LLBCancellableFuture<T>) {
        if let actualDeadline = nioDeadline {
            let timer = cancellable.future.eventLoop.scheduleTask(deadline: actualDeadline) {
                cancellable.cancel(reason: "timeout")
            }

            cancellable.future.whenComplete {
                _ in timer.cancel()
            }
        }
    }
}
