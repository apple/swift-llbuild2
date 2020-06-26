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
import TSCBasic

let gameOfLifeDirectory = AbsolutePath("/tmp/game_of_life")
try localFileSystem.createDirectory(gameOfLifeDirectory, recursive: true)

// Create the build engine's dependencies.
let group = MultiThreadedEventLoopGroup(numberOfThreads: ProcessInfo.processInfo.processorCount)
let db = LLBFileBackedCASDatabase(group: group, path: gameOfLifeDirectory.appending(component: "cas"))
let executor = LLBLocalExecutor(outputBase: gameOfLifeDirectory.appending(component: "executor_output"))
let functionCache = LLBFileBackedFunctionCache(group: group, path: gameOfLifeDirectory.appending(component: "function_cache"))

let engineContext = LLBBasicBuildEngineContext(group: group, db: db, executor: executor)
let buildSystemDelegate = GameOfLifeBuildSystemDelegate(engineContext: engineContext)

// Construct the build engine instance and
let engine = LLBBuildEngine(
    engineContext: engineContext,
    buildFunctionLookupDelegate: buildSystemDelegate,
    configuredTargetDelegate: buildSystemDelegate,
    ruleLookupDelegate: buildSystemDelegate,
    registrationDelegate: buildSystemDelegate,
    executor: executor,
    functionCache: functionCache
)

// Construct the SwiftUI environment object to access the build engine and database.
let environment = GameOfLifeEnvironment(engine: engine, db: db)

// Run the UI.
SwiftUIApplication(GameOfLifeView(), observable: environment).run()
