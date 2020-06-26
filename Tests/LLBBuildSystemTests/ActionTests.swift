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

enum ActionDummyError: Error, Equatable {
    case expectedError
    case unsupportedCommand(String)
}

private class ActionDummyExecutor: LLBExecutor {
    func execute(request: LLBActionExecutionRequest, _ ctx: Context) -> LLBFuture<LLBActionExecutionResponse> {
        let stdoutFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("Success".utf8)), ctx)
        let stderrFuture = ctx.db.put(data: LLBByteBuffer.withData(Data("".utf8)), ctx)

        return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
            return LLBActionExecutionResponse.with {
                $0.exitCode = 0
                $0.outputs = []
                $0.stdoutID = stdoutID
                $0.stderrID = stderrID
            }
        }
    }
}

class ActionTests: XCTestCase {
    private var testGroup: LLBFuturesDispatchGroup! = nil
    private var testExecutor: LLBExecutor! = nil
    private var testDB: LLBTestCASDatabase! = nil
    private var testEngine: LLBTestBuildEngine! = nil

    override func setUp() {
        self.testGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.testExecutor = ActionDummyExecutor()
        self.testDB = LLBTestCASDatabase(group: testGroup)
        self.testEngine = LLBTestBuildEngine(group: testGroup, db: testDB, executor: testExecutor)
    }

    override func tearDown() {
        self.testExecutor = nil
        self.testDB = nil
        self.testEngine = nil
        self.testGroup = nil

    }

    func testSimpleActionNoOutputs() throws {
        let ctx = Context()
        let bytes = LLBByteBuffer.withString("Hello, world!")

        let dataID = try testDB.put(data: bytes, ctx).wait()

        let input = LLBArtifact.source(shortPath: "some/source.txt", dataID: dataID)

        let actionKey = LLBActionKey.with {
            $0.actionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["success"]
                }
                $0.inputs = [input]
                $0.outputs = []
            })
        }

        let actionValue: LLBActionValue = try testEngine.build(actionKey, ctx).wait()
        XCTAssertEqual(actionValue.outputs, [])
    }
}
