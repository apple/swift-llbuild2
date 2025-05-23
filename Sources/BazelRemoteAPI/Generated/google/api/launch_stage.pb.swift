// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: google/api/launch_stage.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

/// The launch stage as defined by [Google Cloud Platform
/// Launch Stages](https://cloud.google.com/terms/launch-stages).
public enum Google_Api_LaunchStage: SwiftProtobuf.Enum {
  public typealias RawValue = Int

  /// Do not use this default value.
  case unspecified // = 0

  /// The feature is not yet implemented. Users can not use it.
  case unimplemented // = 6

  /// Prelaunch features are hidden from users and are only visible internally.
  case prelaunch // = 7

  /// Early Access features are limited to a closed group of testers. To use
  /// these features, you must sign up in advance and sign a Trusted Tester
  /// agreement (which includes confidentiality provisions). These features may
  /// be unstable, changed in backward-incompatible ways, and are not
  /// guaranteed to be released.
  case earlyAccess // = 1

  /// Alpha is a limited availability test for releases before they are cleared
  /// for widespread use. By Alpha, all significant design issues are resolved
  /// and we are in the process of verifying functionality. Alpha customers
  /// need to apply for access, agree to applicable terms, and have their
  /// projects allowlisted. Alpha releases don't have to be feature complete,
  /// no SLAs are provided, and there are no technical support obligations, but
  /// they will be far enough along that customers can actually use them in
  /// test environments or for limited-use tests -- just like they would in
  /// normal production cases.
  case alpha // = 2

  /// Beta is the point at which we are ready to open a release for any
  /// customer to use. There are no SLA or technical support obligations in a
  /// Beta release. Products will be complete from a feature perspective, but
  /// may have some open outstanding issues. Beta releases are suitable for
  /// limited production use cases.
  case beta // = 3

  /// GA features are open to all developers and are considered stable and
  /// fully qualified for production use.
  case ga // = 4

  /// Deprecated features are scheduled to be shut down and removed. For more
  /// information, see the "Deprecation Policy" section of our [Terms of
  /// Service](https://cloud.google.com/terms/)
  /// and the [Google Cloud Platform Subject to the Deprecation
  /// Policy](https://cloud.google.com/terms/deprecation) documentation.
  case deprecated // = 5
  case UNRECOGNIZED(Int)

  public init() {
    self = .unspecified
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .unspecified
    case 1: self = .earlyAccess
    case 2: self = .alpha
    case 3: self = .beta
    case 4: self = .ga
    case 5: self = .deprecated
    case 6: self = .unimplemented
    case 7: self = .prelaunch
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .unspecified: return 0
    case .earlyAccess: return 1
    case .alpha: return 2
    case .beta: return 3
    case .ga: return 4
    case .deprecated: return 5
    case .unimplemented: return 6
    case .prelaunch: return 7
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension Google_Api_LaunchStage: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [Google_Api_LaunchStage] = [
    .unspecified,
    .unimplemented,
    .prelaunch,
    .earlyAccess,
    .alpha,
    .beta,
    .ga,
    .deprecated,
  ]
}

#endif  // swift(>=4.2)

#if swift(>=5.5) && canImport(_Concurrency)
extension Google_Api_LaunchStage: @unchecked Sendable {}
#endif  // swift(>=5.5) && canImport(_Concurrency)

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension Google_Api_LaunchStage: SwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "LAUNCH_STAGE_UNSPECIFIED"),
    1: .same(proto: "EARLY_ACCESS"),
    2: .same(proto: "ALPHA"),
    3: .same(proto: "BETA"),
    4: .same(proto: "GA"),
    5: .same(proto: "DEPRECATED"),
    6: .same(proto: "UNIMPLEMENTED"),
    7: .same(proto: "PRELAUNCH"),
  ]
}
