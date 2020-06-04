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
import LLBBuildSystemProtocol
import NIO
import XCTest

enum ActionExecutionDummyError: Error, Equatable {
    case expectedError
    case unsupportedCommand(String)
}

private class ActionExecutionDummyExecutor: LLBExecutor {
    func execute(request: LLBActionExecutionRequest, engineContext: LLBBuildEngineContext) -> LLBFuture<LLBActionExecutionResponse> {
        let command = request.actionSpec.arguments[0]
        if command == "success" {
            let stdoutFuture = engineContext.db.put(data: LLBByteBuffer.withData(Data("Success".utf8)))
            let stderrFuture = engineContext.db.put(data: LLBByteBuffer.withData(Data("".utf8)))

            return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
                return LLBActionExecutionResponse.with {
                    $0.exitCode = 0
                    // Map the input contents as the outputs.
                    $0.outputs = request.inputs.map { $0.dataID }
                    $0.stdoutID = LLBPBDataID(stdoutID)
                    $0.stderrID = LLBPBDataID(stderrID)
                }
            }
        } else if command == "failure" {
            let stdoutFuture = engineContext.db.put(data: LLBByteBuffer.withData(Data("".utf8)))
            let stderrFuture = engineContext.db.put(data: LLBByteBuffer.withData(Data("Failure".utf8)))

            return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
                return LLBActionExecutionResponse.with {
                    $0.exitCode = 1
                    $0.stdoutID = LLBPBDataID(stdoutID)
                    $0.stderrID = LLBPBDataID(stderrID)
                }
            }
        } else if command == "schedule-error" {
            return engineContext.group.next().makeFailedFuture(ActionExecutionDummyError.expectedError)
        }

        return engineContext.group.next().makeFailedFuture(ActionExecutionDummyError.unsupportedCommand(command))
    }
}

class ActionExecutionTests: XCTestCase {
    private var testExecutor: LLBExecutor! = nil
    private var testEngineContext: LLBTestBuildEngineContext! = nil
    private var testEngine: LLBTestBuildEngine! = nil

    override func setUp() {
        self.testExecutor = ActionExecutionDummyExecutor()
        self.testEngineContext = LLBTestBuildEngineContext(executor: testExecutor)
        self.testEngine = LLBTestBuildEngine(engineContext: testEngineContext)
    }

    override func tearDown() {
        self.testExecutor = nil
        self.testEngine = nil
    }

    private var testDB: LLBTestCASDatabase {
        return testEngineContext.testDB
    }

    func testActionExecution() throws {
        let bytes = LLBByteBuffer.withString("Hello, world!")

        let dataID = try testDB.put(data: bytes).wait()

        let actionExecutionKey = ActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["success"]
                }
                $0.inputs = [
                    .with {
                        $0.dataID = LLBPBDataID(dataID)
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

        let actionExecutionValue: ActionExecutionValue = try testEngine.build(actionExecutionKey).wait()
        let stdout = try XCTUnwrap(testDB.get(LLBDataID(actionExecutionValue.stdoutID)).wait()?.data.asString())
        XCTAssertEqual(stdout, "Success")
    }

    func testActionExecutionFailure() throws {
        let actionExecutionKey = ActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["failure"]
                }
            })
        }

        XCTAssertThrowsError(try testEngine.build(actionExecutionKey).wait()) { error in
            do {
                let actionExecutionError = try XCTUnwrap(error as? ActionExecutionError)

                guard case let .actionExecutionError(stdoutID, stderrID) = actionExecutionError else {
                    XCTFail("Expected an actionExecutionError")
                    return
                }

                let stdout = try XCTUnwrap(testDB.get(stdoutID).wait()?.data.asString())
                XCTAssertEqual(stdout, "")

                let stderr = try XCTUnwrap(testDB.get(stderrID).wait()?.data.asString())
                XCTAssertEqual(stderr, "Failure")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActionExecutionExecutorError() throws {
        let actionExecutionKey = ActionExecutionKey.with {
            $0.actionExecutionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["schedule-error"]
                }
            })
        }

        XCTAssertThrowsError(try testEngine.build(actionExecutionKey).wait()) { error in
            do {
                let actionExecutionError = try XCTUnwrap(error as? ActionExecutionError)

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
