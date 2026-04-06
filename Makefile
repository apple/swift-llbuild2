# This source file is part of the Swift.org open source project
#
# Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

# These commands should be executed any time the proto definitions change. It is
# not required to be generated as part of a regular `swift build` since we're
# checking in the generated sources.
.PHONY:
generate: clean generate-protos

.PHONY:
generate-protos: proto-toolchain
	mkdir -p Sources/llbuild2fx/Generated
	Utilities/tools/bin/protoc \
		-I=Protos \
		--plugin=Utilities/tools/bin/protoc-gen-swift \
		--swift_out=Sources/llbuild2fx/Generated \
		--swift_opt=Visibility=Public \
		--swift_opt=ProtoPathModuleMappings=Protos/module_map.asciipb \
		$$(find Protos/EngineProtocol -name \*.proto)
	mkdir -p Sources/FXCore/CAS/Generated
	Utilities/tools/bin/protoc \
		-I=Protos \
		--plugin=Utilities/tools/bin/protoc-gen-swift \
		--swift_out=Sources/FXCore/CAS/Generated \
		--swift_opt=Visibility=Public \
		--swift_opt=ProtoPathModuleMappings=Protos/module_map.asciipb \
		$$(find Protos/CASProtocol -name \*.proto)
	mkdir -p Sources/llbuild2Testing/CASFileTree/Generated
	Utilities/tools/bin/protoc \
		-I=Protos \
		--plugin=Utilities/tools/bin/protoc-gen-swift \
		--swift_out=Sources/llbuild2Testing/CASFileTree/Generated \
		--swift_opt=Visibility=Package \
		--swift_opt=ProtoPathModuleMappings=Protos/module_map.asciipb \
		$$(find Protos/CASFileTreeProtocol -name \*.proto)

.PHONY:
proto-toolchain:
	Utilities/build_proto_toolchain.sh

.PHONY:
clean:
	rm -rf Sources/llbuild2fx/Generated
	rm -rf Sources/FXCore/CAS/Generated
	rm -rf Sources/llbuild2Testing/CASFileTree/Generated
