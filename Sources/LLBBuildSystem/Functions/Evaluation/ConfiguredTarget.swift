// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemProtocol

extension LLBConfiguredTargetKey: LLBBuildKey {}
extension LLBConfiguredTargetValue: LLBBuildValue {}

public enum LLBConfiguredTargetError: Error {
    /// Internal error if a configured target was requested and no delegate was configured.
    case noDelegate

    /// Error that clients can use to signal that a target was not found for the requested key.
    case notFound(LLBLabel)

    /// Unexpected error coming from the delegate implementation.
    case unexpectedError(Error)

    /// Unexpected type when deserializing the configured target
    case unexpectedType(String)

    /// Case when the delegate errored when evaluating a configured target.
    case delegateError(Error)
}

// Convenience initializer.
public extension LLBConfiguredTargetKey {
    init(rootID: LLBDataID, label: LLBLabel, configurationKey: LLBConfigurationKey? = nil) {
        self.rootID = rootID
        self.label = label
        self.configurationKey = configurationKey ?? LLBConfigurationKey()
    }
}

// Convenience initializer.
extension LLBConfiguredTargetValue {
    init(serializedConfiguredTarget: LLBAnyCodable) {
        self.serializedConfiguredTarget = serializedConfiguredTarget
    }
}

extension LLBConfiguredTargetValue {
    /// Registers a type as a ConfiguredTarget. This is required in order for the type to be able to be decoded at
    /// runtime, since llbuild2 allows dynamic types for ConfiguredTargets.
    public static func register(configuredTargetType: LLBConfiguredTarget.Type) {
        LLBAnyCodable.register(type: configuredTargetType)
    }

    /// Returns the configured target as a ConfiguredTarget type.
    func configuredTarget() throws -> LLBConfiguredTarget {
        guard let configuredTargetType = serializedConfiguredTarget.registeredType() as? LLBConfiguredTarget.Type else {
            throw LLBConfiguredTargetError.unexpectedType(
                "Could not find type for \(serializedConfiguredTarget.typeIdentifier), did you forget to register it?"
            )
        }
        let byteBuffer = LLBByteBuffer.withBytes(ArraySlice<UInt8>(serializedConfiguredTarget.serializedCodable))
        return try configuredTargetType.init(from: byteBuffer)
    }

    /// Returns the configured target if it's possible to cast it to the specified type.
    public func typedConfiguredTarget<C: LLBConfiguredTarget>(as expectedType: C.Type = C.self) throws -> C {
        guard let target = try self.configuredTarget() as? C else {
            throw LLBConfiguredTargetError.unexpectedType("Could not cast target to \(String(describing: C.self))")
        }
        return target
    }
}

final class ConfiguredTargetFunction: LLBBuildFunction<LLBConfiguredTargetKey, LLBConfiguredTargetValue> {
    let configuredTargetDelegate: LLBConfiguredTargetDelegate?

    init(engineContext: LLBBuildEngineContext, configuredTargetDelegate: LLBConfiguredTargetDelegate?) {
        self.configuredTargetDelegate = configuredTargetDelegate
        super.init(engineContext: engineContext)
    }

    override func evaluate(key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<LLBConfiguredTargetValue> {
        guard let delegate = configuredTargetDelegate else {
            return fi.group.next().makeFailedFuture(LLBConfiguredTargetError.noDelegate)
        }
        do {
            return try delegate.configuredTarget(for: key, fi).flatMapThrowing { configuredTarget in
                // Wrap the ConfiguredTarget into an LLBAnyCodable and store that.
                let serializedConfiguredTarget = try LLBAnyCodable(from: configuredTarget)
                return LLBConfiguredTargetValue(serializedConfiguredTarget: serializedConfiguredTarget)
            }.flatMapErrorThrowing { error in
                // Convert any non ConfiguredTargetErrors into ConfiguredTargetError.
                if error is LLBConfiguredTargetError {
                    throw error
                } else {
                    throw LLBConfiguredTargetError.unexpectedError(error)
                }
            }
        } catch {
            return fi.group.next().makeFailedFuture(LLBConfiguredTargetError.delegateError(error))
        }
    }
}
