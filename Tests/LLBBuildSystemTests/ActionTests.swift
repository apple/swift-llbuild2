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

enum ActionDummyError: Error, Equatable {
    case expectedError
    case unsupportedCommand(String)
}

private class ActionDummyExecutor: LLBExecutor {
    let group: LLBFuturesDispatchGroup
    let db: LLBCASDatabase

    init(group: LLBFuturesDispatchGroup, db: LLBCASDatabase) {
        self.group = group
        self.db = db
    }

    func execute(request: LLBActionExecutionRequest) -> LLBFuture<LLBActionExecutionResponse> {
        let stdoutFuture = db.put(data: LLBByteBuffer.withData(Data("Success".utf8)))
        let stderrFuture = db.put(data: LLBByteBuffer.withData(Data("".utf8)))

        return stdoutFuture.and(stderrFuture).map { (stdoutID, stderrID) in
            return LLBActionExecutionResponse.with {
                $0.exitCode = 0
                $0.outputs = []
                $0.stdoutID = LLBPBDataID(stdoutID)
                $0.stderrID = LLBPBDataID(stderrID)
            }
        }
    }
}

class ActionTests: XCTestCase {
    private var testDB: LLBCASDatabase! = nil
    private var testExecutor: LLBExecutor! = nil
    private var testEngine: LLBTestBuildEngine! = nil

    override func setUp() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.testDB = LLBTestCASDatabase(group: group)
        self.testExecutor = ActionDummyExecutor(group: group, db: testDB)

        let testEngineContext = LLBTestBuildEngineContext(group: group, db: testDB, executor: testExecutor)
        self.testEngine = LLBTestBuildEngine(engineContext: testEngineContext)
    }

    override func tearDown() {
        self.testDB = nil
        self.testExecutor = nil
        self.testEngine = nil
    }

    func testSimpleActionNoOutputs() throws {
        let bytes = LLBByteBuffer.withString("Hello, world!")

        let dataID = try testDB.put(data: bytes).wait()

        let input = Artifact.source(shortPath: "some/source.txt", dataID: dataID)

        let actionKey = ActionKey.with {
            $0.actionType = .command(.with {
                $0.actionSpec = .with {
                    $0.arguments = ["success"]
                }
                $0.inputs = [input]
                $0.outputs = []
            })
        }

        let actionValue: ActionValue = try testEngine.build(actionKey).wait()
        XCTAssertEqual(actionValue.outputs, [])
    }
}
