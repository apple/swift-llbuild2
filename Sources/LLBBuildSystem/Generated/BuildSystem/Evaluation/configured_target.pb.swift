// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: BuildSystem/Evaluation/configured_target.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import SwiftProtobuf

import LLBCAS
import llbuild2

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

/// Key to be used when requesting the value of a configured target. A configured target represents a logical target
/// after parsing and being configured by the active configuration. Configured targets have already resolved their
/// dependencies (usually declared through labels). It is up to each build system implementation to define what a
/// configured target looks like, and llbuild2 only enforces that it supports being serialized/deserialized.
public struct LLBConfiguredTargetKey {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// The data ID for the workspace root on where to find the target definition.
  public var rootID: LLBCAS.LLBDataID {
    get {return _rootID ?? LLBCAS.LLBDataID()}
    set {_rootID = newValue}
  }
  /// Returns true if `rootID` has been explicitly set.
  public var hasRootID: Bool {return self._rootID != nil}
  /// Clears the value of `rootID`. Subsequent reads from it will return its default value.
  public mutating func clearRootID() {self._rootID = nil}

  /// The label for the target that is being requested. It is up to the build system implementation to interpret the
  /// label in order to associate it with a target.
  public var label: LLBLabel {
    get {return _label ?? LLBLabel()}
    set {_label = newValue}
  }
  /// Returns true if `label` has been explicitly set.
  public var hasLabel: Bool {return self._label != nil}
  /// Clears the value of `label`. Subsequent reads from it will return its default value.
  public mutating func clearLabel() {self._label = nil}

  /// The configuration key under which this target should be evaluated. Each configured target will be requested
  /// exactly once for each combination of rootID, label and configuration key.
  public var configurationKey: LLBConfigurationKey {
    get {return _configurationKey ?? LLBConfigurationKey()}
    set {_configurationKey = newValue}
  }
  /// Returns true if `configurationKey` has been explicitly set.
  public var hasConfigurationKey: Bool {return self._configurationKey != nil}
  /// Clears the value of `configurationKey`. Subsequent reads from it will return its default value.
  public mutating func clearConfigurationKey() {self._configurationKey = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _rootID: LLBCAS.LLBDataID? = nil
  fileprivate var _label: LLBLabel? = nil
  fileprivate var _configurationKey: LLBConfigurationKey? = nil
}

/// A ConfiguredTargetValue wraps the contents of the user specified configured target. llbuild2 handles the runtime
/// components of serialization and deserialization in order to provide a simpler interface for llbuild2 clients to
/// integrate. A ConfiguredTarget value represents the state of a target after the target has been parsed from its
/// project description file and after the configuration has been applied, but before the target has been evaluated.
public struct LLBConfiguredTargetValue {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// The polymorphic codable wrapper containing the configured target as declared by llbuild2's clients.
  public var serializedConfiguredTarget: llbuild2.LLBAnySerializable {
    get {return _serializedConfiguredTarget ?? llbuild2.LLBAnySerializable()}
    set {_serializedConfiguredTarget = newValue}
  }
  /// Returns true if `serializedConfiguredTarget` has been explicitly set.
  public var hasSerializedConfiguredTarget: Bool {return self._serializedConfiguredTarget != nil}
  /// Clears the value of `serializedConfiguredTarget`. Subsequent reads from it will return its default value.
  public mutating func clearSerializedConfiguredTarget() {self._serializedConfiguredTarget = nil}

  /// The named configured target dependency map. Each entry is either a single provider map or a list of provider
  /// maps, with a name as defined by the build system implementation. Rule implementations can then read the
  /// dependencies providers using these names. LLBConfiguredTargets must implement an API that returns this map
  /// of dependencies.
  public var targetDependencies: [LLBNamedConfiguredTargetDependency] = []

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _serializedConfiguredTarget: llbuild2.LLBAnySerializable? = nil
}

/// A single named entry for dependencies. For example, a Swift target could have multiple library dependencies under
/// the "dependencies" named dependency, and a single tool dependency under the "tool" dependency. Rule implementations
/// can then read the providers from these dependencies using these names as key.
public struct LLBNamedConfiguredTargetDependency {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// The name for this dependency.
  public var name: String = String()

  /// The type of dependency.
  public var type: LLBNamedConfiguredTargetDependency.TypeEnum = .single

  /// The list of providerMaps that correspond to this dependency. For single dependencies, this list must have a
  /// single element. For the list type, it can have any number of elements.
  public var providerMaps: [LLBProviderMap] = []

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  /// The type of dependency, whether it is a single dependency or a list of dependencies.
  public enum TypeEnum: SwiftProtobuf.Enum {
    public typealias RawValue = Int
    case single // = 0
    case list // = 1
    case UNRECOGNIZED(Int)

    public init() {
      self = .single
    }

    public init?(rawValue: Int) {
      switch rawValue {
      case 0: self = .single
      case 1: self = .list
      default: self = .UNRECOGNIZED(rawValue)
      }
    }

    public var rawValue: Int {
      switch self {
      case .single: return 0
      case .list: return 1
      case .UNRECOGNIZED(let i): return i
      }
    }

  }

  public init() {}
}

#if swift(>=4.2)

extension LLBNamedConfiguredTargetDependency.TypeEnum: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [LLBNamedConfiguredTargetDependency.TypeEnum] = [
    .single,
    .list,
  ]
}

#endif  // swift(>=4.2)

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension LLBConfiguredTargetKey: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "LLBConfiguredTargetKey"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "rootID"),
    2: .same(proto: "label"),
    3: .same(proto: "configurationKey"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularMessageField(value: &self._rootID)
      case 2: try decoder.decodeSingularMessageField(value: &self._label)
      case 3: try decoder.decodeSingularMessageField(value: &self._configurationKey)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if let v = self._rootID {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    }
    if let v = self._label {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }
    if let v = self._configurationKey {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: LLBConfiguredTargetKey, rhs: LLBConfiguredTargetKey) -> Bool {
    if lhs._rootID != rhs._rootID {return false}
    if lhs._label != rhs._label {return false}
    if lhs._configurationKey != rhs._configurationKey {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension LLBConfiguredTargetValue: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "LLBConfiguredTargetValue"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "serializedConfiguredTarget"),
    2: .same(proto: "targetDependencies"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularMessageField(value: &self._serializedConfiguredTarget)
      case 2: try decoder.decodeRepeatedMessageField(value: &self.targetDependencies)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if let v = self._serializedConfiguredTarget {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    }
    if !self.targetDependencies.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.targetDependencies, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: LLBConfiguredTargetValue, rhs: LLBConfiguredTargetValue) -> Bool {
    if lhs._serializedConfiguredTarget != rhs._serializedConfiguredTarget {return false}
    if lhs.targetDependencies != rhs.targetDependencies {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension LLBNamedConfiguredTargetDependency: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "LLBNamedConfiguredTargetDependency"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "name"),
    2: .same(proto: "type"),
    3: .same(proto: "providerMaps"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularStringField(value: &self.name)
      case 2: try decoder.decodeSingularEnumField(value: &self.type)
      case 3: try decoder.decodeRepeatedMessageField(value: &self.providerMaps)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.name.isEmpty {
      try visitor.visitSingularStringField(value: self.name, fieldNumber: 1)
    }
    if self.type != .single {
      try visitor.visitSingularEnumField(value: self.type, fieldNumber: 2)
    }
    if !self.providerMaps.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.providerMaps, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: LLBNamedConfiguredTargetDependency, rhs: LLBNamedConfiguredTargetDependency) -> Bool {
    if lhs.name != rhs.name {return false}
    if lhs.type != rhs.type {return false}
    if lhs.providerMaps != rhs.providerMaps {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension LLBNamedConfiguredTargetDependency.TypeEnum: SwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "SINGLE"),
    1: .same(proto: "LIST"),
  ]
}
