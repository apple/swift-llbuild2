// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Atomics
import NIOConcurrencyHelpers
import NIOCore

package enum LLBCancellablePromiseError: Error {
    case promiseFulfilled
    case promiseCancelled
    case promiseLeaked
}

/// A promise that can be cancelled prematurely.
/// The CancellablePromise supports two types of API access:
///     - The writer access that fulfills the promise or cancels it, getting
///       back indication of whether or not that operation was successful.
///     - The reader access that checks if the promise has been fulfilled.
package class LLBCancellablePromise<T>: @unchecked /* because inheritance... */ Sendable {
    /// Underlying promise. Private to avoid messing with out outside
    /// of CancellablePromise lifecycle protection.
    private let promise: FXPromise<T>

    /// The current state of the promise.
    ///     - inProgress: The promise is waiting to be fulfilled or cancelled.
    ///     - fulfilled: The promise has been fulfilled with a value or error.
    ///     - cancelled: The promise has been cancelled via cancel(_:)
    package enum State: Int {
        case inProgress
        case fulfilled
        case cancelled
    }

    /// A state maintaining the lifecycle of the promise.
    let state_: ManagedAtomic<Int>

    package var state: State {
        return State(rawValue: state_.load(ordering: .relaxed))!
    }

    /// The eventual result of the promise.
    package var futureResult: FXFuture<T> {
        return promise.futureResult
    }

    /// Whether the promise was fulfilled or cancelled.
    package var isCompleted: Bool {
        return state != .inProgress
    }

    /// Whether the promise was cancelled.
    package var isCancelled: Bool {
        return state == .cancelled
    }

    /// Initialize a new promise off the given event loop.
    package convenience init(on loop: FXFuturesDispatchLoop) {
        self.init(promise: loop.makePromise())
    }

    /// Initialize a promise directly. Less safe because the promise
    /// could be accidentally fulfilled outside of CancellablePromise lifecycle.
    package init(promise: FXPromise<T>) {
        self.promise = promise
        self.state_ = .init(State.inProgress.rawValue)
    }

    /// Returns `true` if the state has been modified from .inProgress.
    private func modifyState(_ newState: State) -> Bool {
        assert(newState != .inProgress)
        return state_.compareExchange(
            expected: State.inProgress.rawValue, desired: newState.rawValue,
            ordering: .sequentiallyConsistent
        ).0
    }

    /// Fulfill the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    package func fail(_ error: Swift.Error) -> Bool {
        let justModified = modifyState(State.fulfilled)
        if justModified {
            promise.fail(error)
        }
        return justModified
    }

    /// Cancel the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    package func cancel(_ error: Swift.Error) -> Bool {
        let justModified = modifyState(State.cancelled)
        if justModified {
            promise.fail(error)
        }
        return justModified
    }

    /// Fulfill the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    package func succeed(_ value: T) -> Bool {
        let justModified = modifyState(State.fulfilled)
        if justModified {
            promise.succeed(value)
        }
        return justModified
    }

    deinit {
        _ = cancel(LLBCancellablePromiseError.promiseLeaked)
    }
}

extension FXFuture {

    /// Execute the given operation if a specified promise is not complete.
    /// Otherwise encode a `CancellablePromiseError`.
    package func ifNotCompleteThen<P, O>(
        check promise: LLBCancellablePromise<P>, _ operation: @escaping (Value) -> FXFuture<O>
    ) -> FXFuture<O> {
        flatMap { value in
            switch promise.state {
            case .inProgress:
                return operation(value)
            case .fulfilled:
                return self.eventLoop.makeFailedFuture(LLBCancellablePromiseError.promiseFulfilled)
            case .cancelled:
                return self.eventLoop.makeFailedFuture(LLBCancellablePromiseError.promiseCancelled)
            }
        }
    }

    /// Execute the given operation if a specified promise is not complete.
    /// Otherwise encode a `CancellablePromiseError`.
    package func ifNotCompleteMap<P, O>(
        check promise: LLBCancellablePromise<P>, _ operation: @escaping (Value) -> O
    ) -> FXFuture<O> {
        flatMapThrowing { value in
            switch promise.state {
            case .inProgress:
                return operation(value)
            case .fulfilled:
                throw LLBCancellablePromiseError.promiseFulfilled
            case .cancelled:
                throw LLBCancellablePromiseError.promiseCancelled
            }
        }
    }

    /// Post the result of a future onto the cancellable promise.
    package func cascade(to promise: LLBCancellablePromise<Value>) {
        guard promise.isCompleted == false else { return }
        whenComplete { result in
            switch result {
            case .success(let value): _ = promise.succeed(value)
            case .failure(let error): _ = promise.fail(error)
            }
        }
    }
}
