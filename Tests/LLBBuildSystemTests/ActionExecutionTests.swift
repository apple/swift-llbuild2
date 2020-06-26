// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import LLBBuildSystemTestHelpers
import NIO
import XCTest

enum ActionExecutionDummyError: Error, Equatable {
    case expectedError
    case unsupportedCommand(String)
}

private class ActionExecutionDummyExecutor: LLBExecutor {
    func execute(request: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        let command = request.actionSpec.arguments[0]
        if command == "success" {
            let stdoutFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("Success".utf8)), ctx)
            let stderrFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("".utf8)), ctx)

            return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
                return LLBActionExecutionResponse.with {
                    $0.exitCode = 0
                    // Map the input contents as the outputs.
                    $0.outputs = request.inputs.map { $0.dataID }
                    $0.stdoutID = stdoutID
                    $0.stderrID = stderrID
                }
            }
        } else if command == "failure" {
            let stdoutFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("".utf8)), ctx)
            let stderrFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("Failure".utf8)), ctx)

            return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
                return LLBActionExecutionResponse.with {
                    $0.exitCode = 1
                    $0.stdoutID = stdoutID
                    $0.stderrID = stderrID
                }
            }
        } else if command == "schedule-error" {
            return ctx.group.next().makeFailedFuture(ActionExecutionDummyError.expectedError)
        }

        return ctx.group.next().makeFailedFuture(ActionExecutionDummyError.unsupportedCommand(command))
    }
}

class ActionExecutionTests: XCTestCase {
    private var testExecutor: LLBExecutor! = nil
    private var testCtx: Context! = nil
    private var testEngine: LLBTestBuildEngine! = nil

    override func setUp() {
        self.testExecutor = ActionExecutionDummyExecutor()
        self.testCtx = LLBMakeTestContext()
        self.testEngine = LLBTestBuildEngine(group: testCtx.group, db: testCtx.db, executor: self.testExecutor)
    }

    override func tearDown() {
        self.testExecutor = nil
        self.testEngine = nil
    }

    func testActionExecution() throws {
        let ctx = Context()
        let bytes = LLBByteBuffer.withString("Hello, world!")

        let dataID = try testCtx.db.put(data: bytes, ctx).wait()

        let actionExecutionKey = LLBActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["success"]
                }
                $0.inputs = [
                    .with {
                        $0.dataID = dataID
                        $0.path = "some/path"
                        $0.type = .file
                    },
                ]
                $0.outputs = [
                    .with {
                        $0.path = "some/other/path"
                        $0.type = .file
                    },
                ]
            })
        }

        let actionExecutionValue: LLBActionExecutionValue = try testEngine.build(actionExecutionKey, ctx).wait()
        let stdout = try XCTUnwrap(testCtx.db.get(actionExecutionValue.stdoutID, ctx).wait()?.data.asString())
        XCTAssertEqual(stdout, "Success")
    }

    func testActionExecutionFailure() throws {
        let ctx = Context()
        let actionExecutionKey = LLBActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["failure"]
                }
            })
        }

        XCTAssertThrowsError(try testEngine.build(actionExecutionKey, ctx).wait()) { error in
            do {
                let actionExecutionError = try XCTUnwrap(error as? LLBActionExecutionError)

                guard case let .actionExecutionError(stdoutID, stderrID) = actionExecutionError else {
                    XCTFail("Expected an actionExecutionError")
                    return
                }

                let stdout = try XCTUnwrap(testCtx.db.get(stdoutID, ctx).wait()?.data.asString())
                XCTAssertEqual(stdout, "")

                let stderr = try XCTUnwrap(testCtx.db.get(stderrID, ctx).wait()?.data.asString())
                XCTAssertEqual(stderr, "Failure")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActionExecutionExecutorError() throws {
        let ctx = Context()
        let actionExecutionKey = LLBActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["schedule-error"]
                }
            })
        }

        XCTAssertThrowsError(try testEngine.build(actionExecutionKey, ctx).wait()) { error in
            do {
                let actionExecutionError = try XCTUnwrap(error as? LLBActionExecutionError)

                guard case let .executorError(underlyingError) = actionExecutionError else {
                    XCTFail("Expected a schedulingError")
                    return
                }
                let dummyError = try XCTUnwrap(underlyingError as? ActionExecutionDummyError)
                XCTAssertEqual(dummyError, ActionExecutionDummyError.expectedError)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
