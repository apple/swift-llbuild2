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
    let group: LLBFuturesDispatchGroup
    let db: LLBCASDatabase

    init(group: LLBFuturesDispatchGroup, db: LLBCASDatabase) {
        self.group = group
        self.db = db
    }

    func execute(request: LLBActionExecutionRequest) -> LLBFuture<LLBActionExecutionResponse> {
        let command = request.actionSpec.arguments[0]
        if command == "success" {
            let stdoutFuture = db.put(data: LLBByteBuffer.withData(Data("Success".utf8)))
            let stderrFuture = db.put(data: LLBByteBuffer.withData(Data("".utf8)))

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
            let stdoutFuture = db.put(data: LLBByteBuffer.withData(Data("".utf8)))
            let stderrFuture = db.put(data: LLBByteBuffer.withData(Data("Failure".utf8)))

            return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
                return LLBActionExecutionResponse.with {
                    $0.exitCode = 1
                    $0.stdoutID = LLBPBDataID(stdoutID)
                    $0.stderrID = LLBPBDataID(stderrID)
                }
            }
        } else if command == "schedule-error" {
            return group.next().makeFailedFuture(ActionExecutionDummyError.expectedError)
        }

        return group.next().makeFailedFuture(ActionExecutionDummyError.unsupportedCommand(command))
    }
}

class ActionExecutionTests: XCTestCase {
    private var testDB: LLBCASDatabase! = nil
    private var testExecutor: LLBExecutor! = nil
    private var testEngine: LLBTestBuildEngine! = nil

    override func setUp() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.testDB = LLBTestCASDatabase(group: group)
        self.testExecutor = ActionExecutionDummyExecutor(group: group, db: testDB)

        let testEngineContext = LLBTestBuildEngineContext(group: group, db: testDB, executor: testExecutor)
        self.testEngine = LLBTestBuildEngine(engineContext: testEngineContext)
    }

    override func tearDown() {
        self.testDB = nil
        self.testExecutor = nil
        self.testEngine = nil
    }

    func testActionExecution() throws {
        let contents = "Hello, world!"
        let bytes = LLBByteBuffer.withData(Data(contents.utf8))

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
        let stdoutData = try XCTUnwrap(testDB.get(LLBDataID(actionExecutionValue.stdoutID)).wait()?.data)
        XCTAssertEqual(String(data: Data(stdoutData.readableBytesView), encoding: .utf8), "Success")
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

                let stdoutData = try XCTUnwrap(testDB.get(stdoutID).wait()?.data)
                XCTAssertEqual(String(data: Data(stdoutData.readableBytesView), encoding: .utf8), "")

                let stderrData = try XCTUnwrap(testDB.get(stderrID).wait()?.data)
                XCTAssertEqual(String(data: Data(stderrData.readableBytesView), encoding: .utf8), "Failure")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActionExecutionSchedulingError() throws {
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

                guard case let .schedulingError(underlyingError) = actionExecutionError else {
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
