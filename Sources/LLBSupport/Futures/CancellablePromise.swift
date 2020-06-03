// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers


public enum LLBCancellablePromiseError: Error {
case promiseFulfilled
case promiseCancelled
case promiseLeaked
}

/// A promise that can be cancelled prematurely.
/// The CancellablePromise supports two types of API access:
///     - The writer access that fulfills the promise or cancels it, getting
///       back indication of whether or not that operation was successful.
///     - The reader access that checks if the promise has been fulfilled.
open class LLBCancellablePromise<T> {
    /// Underlying promise. Private to avoid messing with out outside
    /// of CancellablePromise lifecycle protection.
    private let promise: LLBPromise<T>

    /// The current state of the promise.
    ///     - inProgress: The promise is waiting to be fulfilled or cancelled.
    ///     - fulfilled: The promise has been fulfilled with a value or error.
    ///     - cancelled: The promise has been cancelled via cancel(_:)
    public enum State: Int {
    case inProgress
    case fulfilled
    case cancelled
    }

    /// A state maintaining the lifecycle of the promise.
    @usableFromInline
    let state_: UnsafeEmbeddedAtomic<Int>

    @inlinable
    public var state: State {
        return State(rawValue: state_.load())!
    }

    /// The eventual result of the promise.
    public var futureResult: LLBFuture<T> {
        return promise.futureResult
    }

    /// Whether the promise was fulfilled or cancelled.
    @inlinable
    public var isCompleted: Bool {
        return state != .inProgress
    }

    /// Whether the promise was cancelled.
    @inlinable
    public var isCancelled: Bool {
        return state == .cancelled
    }

    /// Initialize a new promise off the given event loop.
    public convenience init(on loop: LLBFuturesDispatchLoop) {
        self.init(promise: loop.makePromise())
    }

    /// Initialize a promise directly. Less safe because the promise
    /// could be accidentally fulfilled outside of CancellablePromise lifecycle.
    public init(promise: LLBPromise<T>) {
        self.promise = promise
        self.state_ = .init(value: State.inProgress.rawValue)
    }

    /// Returns `true` if the state has been modified from .inProgress.
    private func modifyState(_ newState: State) -> Bool {
        assert(newState != .inProgress)
        return state_.compareAndExchange(expected: State.inProgress.rawValue, desired: newState.rawValue)
    }

    /// Fulfill the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    open func fail(_ error: Swift.Error) -> Bool {
        let justModified = modifyState(State.fulfilled)
        if justModified {
            promise.fail(error)
        }
        return justModified
    }

    /// Cancel the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    open func cancel(_ error: Swift.Error) -> Bool {
        let justModified = modifyState(State.cancelled)
        if justModified {
            promise.fail(error)
        }
        return justModified
    }

    /// Fulfill the promise and return `true` if the promise was been fulfilled
    /// by this call, as opposed to having aready been fulfilled.
    open func succeed(_ value: T) -> Bool {
        let justModified = modifyState(State.fulfilled)
        if justModified {
            promise.succeed(value)
        }
        return justModified
    }

    deinit {
        _ = cancel(LLBCancellablePromiseError.promiseLeaked)
        state_.destroy()
    }
}

extension LLBFuture {

    /// Execute the given operation if a specified promise is not complete.
    /// Otherwise encode a `CancellablePromiseError`.
    @inlinable
    public func ifNotCompleteThen<P, O>(check promise: LLBCancellablePromise<P>, _ operation: @escaping (Value) -> LLBFuture<O>) -> LLBFuture<O> {
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
    @inlinable
    public func ifNotCompleteMap<P, O>(check promise: LLBCancellablePromise<P>, _ operation: @escaping (Value) -> O) -> LLBFuture<O> {
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
    @inlinable
    public func cascade(to promise: LLBCancellablePromise<Value>) {
        guard promise.isCompleted == false else { return }
        whenComplete { result in
            switch result {
            case let .success(value): _ = promise.succeed(value)
            case let .failure(error): _ = promise.fail(error)
            }
        }
    }
}
