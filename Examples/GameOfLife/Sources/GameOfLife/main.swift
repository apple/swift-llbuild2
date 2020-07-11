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
logger.logLevel = .debug
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

    func actionScheduled(action: LLBBuildEventActionDescription) {
        logger.debug("Action scheduled: \(action.description)")
    }

    func actionCompleted(action: LLBBuildEventActionDescription) {
        logger.debug("Action completed: \(action.description)")
    }

    func actionExecutionStarted(action: LLBBuildEventActionDescription) {
        logger.debug("Action execution started: \(action.description)")
    }

    func actionExecutionCompleted(action: LLBBuildEventActionDescription, result: LLBActionResult) {
        logger.debug("Action action execution completed: \(action.description) - \(result)")
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
