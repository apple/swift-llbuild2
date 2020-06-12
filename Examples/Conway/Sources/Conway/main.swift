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

// Register the build system related types as required for polymorphic encoding.
ConfigurationKey.register(fragmentKeyType: ConwayConfigurationKey.self)
ConfigurationValue.register(fragmentType: ConwayConfigurationFragment.self)
ConfiguredTargetValue.register(configuredTargetType: CellTarget.self)
ConfiguredTargetValue.register(configuredTargetType: BoardTarget.self)

// Create the build engine's dependencies.
let group = MultiThreadedEventLoopGroup(numberOfThreads: ProcessInfo.processInfo.processorCount)
let db = LLBInMemoryCASDatabase(group: group)
let executor = LLBLocalExecutor(outputBase: AbsolutePath("/tmp/conway"))
let engineContext = LLBBasicBuildEngineContext(group: group, db: db, executor: executor)
let buildSystemDelegate = ConwayBuildSystemDelegate(engineContext: engineContext)

// Construct the build engine instance and
let engine = LLBBuildEngine(
    engineContext: engineContext,
    buildFunctionLookupDelegate: buildSystemDelegate,
    configuredTargetDelegate: buildSystemDelegate,
    ruleLookupDelegate: buildSystemDelegate
)

// Construct the SwiftUI environment object to access the build engine and database.
let environment = ConwayEnvironment(engine: engine, db: db)

// Run the UI.
SwiftUIApplication(ConwayView(), observable: environment).run()
