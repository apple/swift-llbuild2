// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemUtil
import LLBBuildSystemTestHelpers
import TSCBasic
import XCTest

class LocalExecutorTests: XCTestCase {
    func testBasicExecution() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["/bin/bash", "-c", "echo black lives matter > some/path"]
                }
                $0.inputs = []
                $0.outputs = [
                    .with {
                        $0.path = "some/path"
                        $0.type = .file
                    }
                ]
            }

            let response = try localExecutor.execute(request: request, ctx).wait()
            let contents = try LLBCASFSClient(ctx.db).fileContents(for: response.outputs[0], ctx)
            XCTAssertEqual(contents, "black lives matter\n")
        }
    }

    func testCommandNotFoundError() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["racism"]
                }
            }

            XCTAssertThrowsError(try localExecutor.execute(request: request, ctx).wait()) { error in
                guard case let LLBLocalExecutorError.unexpected(underlyingError) = error else {
                    XCTFail("Unexpected error type")
                    return
                }

                XCTAssertEqual(String(describing: underlyingError), "could not find executable for 'racism'")
            }
        }
    }

    func testActionFailure() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["/bin/bash", "-c", "false"]
                }
            }

            let result = try localExecutor.execute(request: request, ctx).wait()
            XCTAssertEqual(result.exitCode, 1)
            XCTAssert(result.outputs.isEmpty)
        }
    }

    func testMissingOutputFile() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["/bin/bash", "-c", "true"]
                }
                $0.outputs = [
                    .with {
                        $0.path = "some/path"
                        $0.type = .file
                    }
                ]
            }

            XCTAssertThrowsError(try localExecutor.execute(request: request, ctx).wait()) { error in
                guard case let LLBLocalExecutorError.unexpected(underlyingError) = error,
                      let fsError = underlyingError as? FileSystemError else {
                    XCTFail("Unexpected error type")
                    return
                }

                XCTAssertEqual(fsError.kind, .noEntry)
            }
        }
    }

    func testMissingOutputDirectory() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["/bin/bash", "-c", "true"]
                }
                $0.outputs = [
                    .with {
                        $0.path = "some/path"
                        $0.type = .directory
                    }
                ]
            }

            let result = try localExecutor.execute(request: request, ctx).wait()
            try LLBCASFSClient(ctx.db).load(result.outputs[0], ctx).map { node in
                guard let tree = node.tree else {
                    XCTFail("expected output to be a tree")
                    return
                }

                XCTAssert(tree.files.isEmpty)
            }.wait() as Void
        }
    }

    func testExecutionWithInput() throws {
        try withTemporaryDirectory { tempDirectory in
            let localExecutor = LLBLocalExecutor(outputBase: tempDirectory)
            let ctx = LLBMakeTestContext()

            let bytes = LLBByteBuffer.withString("I can't breathe")
            let dataID = try ctx.db.put(data: bytes, ctx).wait()

            let request = LLBActionExecutionRequest.with {
                $0.actionSpec = .with {
                    $0.arguments = ["/bin/bash", "-c", "cat some/input > some/path"]
                }
                $0.inputs = [
                    .with {
                        $0.path = "some/input"
                        $0.type = .file
                        $0.dataID = dataID
                    }
                ]
                $0.outputs = [
                    .with {
                        $0.path = "some/path"
                        $0.type = .file
                    }
                ]
            }

            let response = try localExecutor.execute(request: request, ctx).wait()
            let contents = try LLBCASFSClient(ctx.db).fileContents(for: response.outputs[0], ctx)
            XCTAssertEqual(contents, "I can't breathe")
        }
    }
}
