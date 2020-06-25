// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

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
    init(serializedConfiguredTarget: LLBAnySerializable, targetDependencies: [LLBNamedConfiguredTargetDependency]) {
        self.serializedConfiguredTarget = serializedConfiguredTarget
        self.targetDependencies = targetDependencies
    }
}

extension LLBConfiguredTargetValue {
    /// Returns the configured target as a ConfiguredTarget type.
    func configuredTarget(registry: LLBSerializableLookup) throws -> LLBConfiguredTarget {
        return try serializedConfiguredTarget.deserialize(registry: registry)
    }

    /// Returns the configured target if it's possible to cast it to the specified type.
    public func typedConfiguredTarget<C: LLBConfiguredTarget>(as expectedType: C.Type = C.self, registry: LLBSerializableLookup) throws -> C {
        guard let target = try self.configuredTarget(registry: registry) as? C else {
            throw LLBConfiguredTargetError.unexpectedType("Could not cast target to \(String(describing: C.self))")
        }
        return target
    }
}

/// Helper type used to handle the dependency type and provider map list across future callbacks.
fileprivate enum NamedProviderMapType: Comparable {
    case single(String, LLBProviderMap)
    case list(String, [LLBProviderMap])
    
    var name: String {
        switch self {
        case let .single(name, _):
            return name
        case let .list(name, _):
            return name
        }
    }
    
    var providerMapsAsArray: [LLBProviderMap] {
        switch self {
        case let .single(_, providerMap):
            return [providerMap]
        case let .list(_, providerMaps):
            return providerMaps
        }
    }
    
    var protoType: LLBNamedConfiguredTargetDependency.TypeEnum {
        switch self {
        case .single:
            return .single
        case .list:
            return .list
        }
    }
    
    static func < (lhs: NamedProviderMapType, rhs: NamedProviderMapType) -> Bool {
        lhs.name < rhs.name
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
            return try delegate.configuredTarget(for: key, fi).flatMap { configuredTarget in
                var namedProviderMapFutures = [LLBFuture<NamedProviderMapType>]()
                
                // Request all dependencies as declared by the configured target, so they can be added to the
                // configuration value.
                for (name, type) in configuredTarget.targetDependencies {
                    let namedProviderMapFuture: LLBFuture<NamedProviderMapType>
                    switch type {
                    case let .single(label, configurationKey):
                        let dependencyKey = LLBConfiguredTargetKey(
                            rootID: key.rootID,
                            label: label,
                            // If there was no configurationKey specified, use this targets configuration.
                            configurationKey: configurationKey ?? key.configurationKey
                        )
                        namedProviderMapFuture = fi.requestDependency(dependencyKey).map { NamedProviderMapType.single(name, $0) }
                    case let .list(labels, configurationKey):
                        let dependencyKeys = labels.map {
                            LLBConfiguredTargetKey(
                                rootID: key.rootID,
                                label: $0,
                                // If there was no configurationKey specified, use this targets configuration.
                                configurationKey: configurationKey ?? key.configurationKey
                            )
                        }
                        namedProviderMapFuture = fi.requestDependencies(dependencyKeys).map { NamedProviderMapType.list(name, $0) }
                    }
                    
                    namedProviderMapFutures.append(namedProviderMapFuture)
                }
                
                return LLBFuture.whenAllSucceed(namedProviderMapFutures, on: fi.group.next()).map { (configuredTarget, $0) }
            }.flatMapThrowing { (configuredTarget: LLBConfiguredTarget, namedProviderMaps: [NamedProviderMapType]) in
                // Wrap the ConfiguredTarget into an LLBAnySerializable and store that.
                let serializedConfiguredTarget = try LLBAnySerializable(from: configuredTarget)
                
                // Sort the provider maps for deterministic outputs.
                let targetDependencies = namedProviderMaps.sorted(by: <).map { namedProviderMap in
                    return LLBNamedConfiguredTargetDependency.with {
                        $0.name = namedProviderMap.name
                        $0.type = namedProviderMap.protoType
                        $0.providerMaps = namedProviderMap.providerMapsAsArray
                    }
                }
                
                return LLBConfiguredTargetValue(
                    serializedConfiguredTarget: serializedConfiguredTarget,
                    targetDependencies: targetDependencies
                )
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
