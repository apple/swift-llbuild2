#!/bin/bash -eu
#
# This source file is part of the Swift.org open source project
#
# Copyright (c) 2020 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

ROOT_DIR="$(dirname $(dirname "$0"))"

# Note: The LLBArtifact struct was manually edited to be a class instead of a struct. This was made on purpose
# to allow for a nice API when using Artifacts to construct action graphs, since it means that users can use a single
# reference to the LLBArtifact object that can get updated dynamically to reference the artifact owner that generates it
# after the Artifact was created and moved around. I agree that this is a signal that SwiftProtobuf might be a bad fit
# for this problem, but the benefits that we get around serialization and interface definition through proto files
# outweighs this cost and we're ok with having this technical debt in the time being. If we ever move to a nicer
# serialization mechanism, we can remove this restriction (Artifact just needs to be a class for the API to be nice).

ARTIFACT_PB_SWIFT="${ROOT_DIR}/Sources/LLBBuildSystem/Generated/BuildSystem/Evaluation/artifact.pb.swift"

sed -i -e 's/public struct LLBArtifact/public final class LLBArtifact/' "${ARTIFACT_PB_SWIFT}"
sed -i -e 's/public mutating func/public func/' "${ARTIFACT_PB_SWIFT}"
