// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers

public protocol LLBCancelProtocol {
    func cancel(reason: String?)
}

/// An object serving as a cancellation handler which can
/// be supplied a cancellation procedure much later in its lifetime.
public final class LLBCanceller {
    private let mutex_ = NIOConcurrencyHelpers.Lock()

    /// Whether and why it was cancelled.
    private var finalReason_: FinalReason? = nil

    /// A handler to when the cancellation is requested.
    private var handler_: LLBCancelProtocol?

    /// A reason for reaching the final state.
    private enum FinalReason {
    /// Cancelled with a specified reason.
    case cancelled(reason: String)
    /// Cancellation won't be needed.
    case abandoned
    }

    public init(_ cancelHandler: LLBCancelProtocol? = nil) {
        handler_ = cancelHandler
    }

    /// Checks whether the object has been cancelled.
    public var isCancelled: Bool {
        mutex_.lock()
        guard case .cancelled? = finalReason_ else {
            mutex_.unlock()
            return false
        }
        mutex_.unlock()
        return true
    }

    /// Return the reason for cancelling.
    public var cancelReason: String? {
        mutex_.lock()
        guard case let .cancelled(reason)? = finalReason_ else {
            mutex_.unlock()
            return nil
        }
        mutex_.unlock()
        return reason
    }

    /// Atomically replace the cancellation handler.
    public func set(handler newHandler: LLBCancelProtocol?) {
        mutex_.lock()
        let oldHandler = handler_
        handler_ = newHandler
        if case .cancelled(let reason) = finalReason_ {
            oldHandler?.cancel(reason: reason)
            newHandler?.cancel(reason: reason)
        }
        mutex_.unlock()
    }

    /// Do not cancel anything even if requested.
    public func abandon() {
        mutex_.lock()
        finalReason_ = .abandoned
        handler_ = nil
        mutex_.unlock()
    }

    /// Cancel an outstanding operation.
    public func cancel(reason specifiedReason: String? = nil) {
        mutex_.lock()

        guard finalReason_ == nil else {
            // Already cancelled or abandoned.
            return
        }

        let reason = specifiedReason ?? "no reason given"
        finalReason_ = .cancelled(reason: reason)
        let handler = handler_

        mutex_.unlock()

        handler?.cancel(reason: reason)
    }

    deinit {
        mutex_.lock()
        guard case .cancelled(let reason) = finalReason_, let handler = handler_ else {
            mutex_.unlock()
            return
        }
        mutex_.unlock()
        handler.cancel(reason: reason + " (in deinit)")
    }
}

// Allow Canceller serve as a cancellation handler.
extension LLBCanceller: LLBCancelProtocol { }

/// Create a chain of single-purpose handlers.
public final class LLBCancelHandlersChain: LLBCancelProtocol {
    private let lock = NIOConcurrencyHelpers.Lock()
    private var head: LLBCancelProtocol?
    private var tail: LLBCancelProtocol?

    public init(_ first: LLBCancelProtocol? = nil, _ second: LLBCancelProtocol? = nil) {
        self.head = first
        self.tail = second
    }

    /// Add another handler to the chain.
    public func add(handler: LLBCancelProtocol, for canceller: LLBCanceller) {
        lock.withLockVoid {
            guard let head = self.head else {
                self.head = handler
                return
            }
            guard let tail = self.tail else {
                self.tail = handler
                return
            }
            self.head = handler
            self.tail = LLBCancelHandlersChain(head, tail)
        }

        if let reason = canceller.cancelReason {
            cancel(reason: reason)
        }
    }

    /// Cancel the operations in the handlers chain.
    public func cancel(reason: String?) {
        let (h, t): (LLBCancelProtocol?, LLBCancelProtocol?) = lock.withLock {
            let pair = (self.head, self.tail)
            self.head = nil
            self.tail = nil
            return pair
        }
        h?.cancel(reason: reason)
        t?.cancel(reason: reason)
    }
}
