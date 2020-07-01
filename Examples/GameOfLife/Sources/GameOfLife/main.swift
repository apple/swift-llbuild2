// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


import LLBBuildSystem
import llbuild2
import NIO
import Foundation
import LLBUtil
import LLBBuildSystemUtil
import Logging
import TSCBasic

let gameOfLifeDirectory = AbsolutePath("/tmp/game_of_life")
try localFileSystem.createDirectory(gameOfLifeDirectory, recursive: true)

var ctx = Context()
ctx.group = MultiThreadedEventLoopGroup(numberOfThreads: ProcessInfo.processInfo.processorCount)
ctx.db = LLBFileBackedCASDatabase(group: ctx.group, path: gameOfLifeDirectory.appending(component: "cas"))

var logger = Logger(label: "org.swift.llbuild2.game_of_life")
logger.logLevel = .info
ctx.logger = logger

// Create the build engine's dependencies.
let executor = LLBLocalExecutor(outputBase: gameOfLifeDirectory.appending(component: "executor_output"))
let functionCache = LLBFileBackedFunctionCache(
    group: ctx.group,
    path: gameOfLifeDirectory.appending(component: "function_cache"),
    version: "1"
)

let buildSystemDelegate = GameOfLifeBuildSystemDelegate()

class GameOfLifeBuildEventDelegate: LLBBuildEventDelegate {
    func targetEvaluationRequested(label: LLBLabel) {
        logger.debug("Target \(label.canonical) being evaluated")
    }

    func targetEvaluationCompleted(label: LLBLabel) {
        logger.debug("Target \(label.canonical) evaluated")
    }

    func actionRequested(actionKey: LLBActionExecutionKey) {
        logger.debug("Action requested: \(actionKey.stableHashValue)")
    }

    func actionCompleted(actionKey: LLBActionExecutionKey, result: LLBActionResult) {
        logger.debug("Action completed: \(actionKey.stableHashValue) - \(result)")
    }
}

ctx.buildEventDelegate = GameOfLifeBuildEventDelegate()

// Construct the build engine instance and
let engine = LLBBuildEngine(
    group: ctx.group,
    db: ctx.db,
    buildFunctionLookupDelegate: buildSystemDelegate,
    configuredTargetDelegate: buildSystemDelegate,
    ruleLookupDelegate: buildSystemDelegate,
    registrationDelegate: buildSystemDelegate,
    executor: executor,
    functionCache: functionCache
)

// Construct the SwiftUI environment object to access the build engine and database.
let environment = GameOfLifeEnvironment(engine: engine, ctx)

// Run the UI.
SwiftUIApplication(GameOfLifeView(), observable: environment).run()
