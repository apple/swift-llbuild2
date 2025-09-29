// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import NIOConcurrencyHelpers

public final class TaskCancellationRegistry {
    private var triggers: NIOLockedValueBox<[UUID: () -> Void]> = NIOLockedValueBox([:])

    public init() {

    }

    public func registerForCancellation(_ trigger: @escaping () -> Void) -> UUID {
        let uuid = UUID()
        triggers.withLockedValue { triggers in
            triggers[uuid] = trigger
        }
        return uuid
    }

    public func deregisterForCancellation(taskID uuid: UUID) {
        triggers.withLockedValue { triggers in
            triggers[uuid] = nil
        }
    }

    public func cancelAllTasks() {
        triggers.withLockedValue { triggers in
            for (_, trigger) in triggers {
                trigger()
            }
            triggers = [:]
        }
    }

    static func makeCancellableTask<ValueType>(_ fn: @escaping () async throws -> ValueType, _ ctx: Context) -> LLBFuture<ValueType> {
        let promise = ctx.group.any().makePromise(of: ValueType.self)

        // This creates a new unstrcutured Task context which will not be cancelled when our potentially parent Task context is cancelled. Capture the task here and register it with task cancellation registery so clients can explicitly handle cancellation of the unstrcutured Task created.
        let task = promise.completeWithTask {
            try await fn()
        }

        var taskUUID: UUID?
        if let taskCancellationRegistry = ctx.taskCancellationRegistry {
            taskUUID = taskCancellationRegistry.registerForCancellation {
                task.cancel()
            }
        }

        return promise.futureResult.always { _ in
            if let taskUUID = taskUUID {
                ctx.taskCancellationRegistry?.deregisterForCancellation(taskID: taskUUID)
            }
        }
    }
}

extension Context {
    public var taskCancellationRegistry: TaskCancellationRegistry? {
        get {
            return (self[ObjectIdentifier(TaskCancellationRegistry.self), as: TaskCancellationRegistry.self])
        }
        set {
            self[ObjectIdentifier(TaskCancellationRegistry.self)] = newValue
        }
    }
}

