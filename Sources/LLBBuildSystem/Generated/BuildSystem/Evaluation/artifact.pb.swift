// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: BuildSystem/Evaluation/artifact.proto
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

import LLBBuildSystemProtocol
import LLBCAS

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

//// An Artifact is the unit with which files and directories are represented in llbuild2. It contains not the contents
//// of the sources or intermediate files and directories, but instead contains the necessary data required to resolve
//// a particular input (or output) artifact during execution time. In some ways, it can be viewed as a future where
//// the result (ArtifactValue) is a reference to the actual built contents of the artifact.
public struct Artifact {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  //// Represents what type of Artifact reference this is.
  public var originType: Artifact.OneOf_OriginType? = nil

  //// Source artifacts are inputs to the build, and as such, have a known dataID at the beginning of the build.
  public var source: LLBCAS.LLBPBDataID {
    get {
      if case .source(let v)? = originType {return v}
      return LLBCAS.LLBPBDataID()
    }
    set {originType = .source(newValue)}
  }

  //// A short path representation of the artifact. This usually includes the configuration independent paths.
  public var shortPath: String = String()

  //// A root under which to make the short path relative to. This usually includes configuration elements to use for
  //// deduplication when the a target is evaluated multiple times during a build under different configurations.
  public var root: String = String()

  //// The type of artifact that this represents.
  public var type: LLBBuildSystemProtocol.LLBArtifactType = .file

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  //// Represents what type of Artifact reference this is.
  public enum OneOf_OriginType: Equatable {
    //// Source artifacts are inputs to the build, and as such, have a known dataID at the beginning of the build.
    case source(LLBCAS.LLBPBDataID)

  #if !swift(>=4.1)
    public static func ==(lhs: Artifact.OneOf_OriginType, rhs: Artifact.OneOf_OriginType) -> Bool {
      switch (lhs, rhs) {
      case (.source(let l), .source(let r)): return l == r
      }
    }
  #endif
  }

  public init() {}
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension Artifact: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "Artifact"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "source"),
    2: .same(proto: "shortPath"),
    3: .same(proto: "root"),
    4: .same(proto: "type"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1:
        var v: LLBCAS.LLBPBDataID?
        if let current = self.originType {
          try decoder.handleConflictingOneOf()
          if case .source(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {self.originType = .source(v)}
      case 2: try decoder.decodeSingularStringField(value: &self.shortPath)
      case 3: try decoder.decodeSingularStringField(value: &self.root)
      case 4: try decoder.decodeSingularEnumField(value: &self.type)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if case .source(let v)? = self.originType {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    }
    if !self.shortPath.isEmpty {
      try visitor.visitSingularStringField(value: self.shortPath, fieldNumber: 2)
    }
    if !self.root.isEmpty {
      try visitor.visitSingularStringField(value: self.root, fieldNumber: 3)
    }
    if self.type != .file {
      try visitor.visitSingularEnumField(value: self.type, fieldNumber: 4)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: Artifact, rhs: Artifact) -> Bool {
    if lhs.originType != rhs.originType {return false}
    if lhs.shortPath != rhs.shortPath {return false}
    if lhs.root != rhs.root {return false}
    if lhs.type != rhs.type {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
