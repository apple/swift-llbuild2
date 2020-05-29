#!/bin/bash -eu
#
# This source file is part of the Swift.org open source project
#
# Copyright (c) 2020 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


PROTOC_ZIP=protoc-3.12.2-osx-x86_64.zip
PROTOC_URL="https://github.com/protocolbuffers/protobuf/releases/download/v3.12.2/$PROTOC_ZIP"
GRPC_SWIFT_REPO=https://github.com/grpc/grpc-swift.git

UTILITIES_DIR="$(dirname "$0")"
TOOLS_DIR="$UTILITIES_DIR/tools"
GRPC_SWIFT_DIR="$TOOLS_DIR/grpc-swift"

mkdir -p "$TOOLS_DIR"

if [[ ! -f "$UTILITIES_DIR/tools/$PROTOC_ZIP" ]]; then
    curl -L "$PROTOC_URL" --output "$TOOLS_DIR/$PROTOC_ZIP"
    unzip -o "$TOOLS_DIR/$PROTOC_ZIP" -d "$TOOLS_DIR"
fi

if [[ -d "$GRPC_SWIFT_DIR" ]]; then
    git -C "$GRPC_SWIFT_DIR" pull origin master
else
    git clone "$GRPC_SWIFT_REPO" "$GRPC_SWIFT_DIR"
fi

make plugins -C "$GRPC_SWIFT_DIR"

cp -f "$TOOLS_DIR"/grpc-swift/.build/release/protoc-gen*swift "$TOOLS_DIR/bin"
