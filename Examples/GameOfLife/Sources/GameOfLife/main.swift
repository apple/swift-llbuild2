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

var ctx = Context()
ctx.group = MultiThreadedEventLoopGroup(numberOfThreads: ProcessInfo.processInfo.processorCount)
ctx.db = LLBFileBackedCASDatabase(group: ctx.group, path: gameOfLifeDirectory.appending(component: "cas"))
class caca {
    init() {}
}
ctx[ObjectIdentifier(caca.self)] = caca()

// Create the build engine's dependencies.
let executor = LLBLocalExecutor(outputBase: gameOfLifeDirectory.appending(component: "executor_output"))
let functionCache = LLBFileBackedFunctionCache(group: ctx.group, path: gameOfLifeDirectory.appending(component: "function_cache"))

let buildSystemDelegate = GameOfLifeBuildSystemDelegate()

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
