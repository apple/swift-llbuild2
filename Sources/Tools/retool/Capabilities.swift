// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCBasic
import Foundation
import ArgumentParser

import GRPC
import LLBRETool

struct Capabilities: ParsableCommand {

    @OptionGroup()
    var options: Options

    @Option(help: "The instance of the execution system to operate against")
    var instanceName: String?

    func run() throws {
        let toolOptions = try LLBRETool.Options(
            frontend: self.options.url.toConnectionTarget()
        )

        let tool = RETool(toolOptions)
        let response = try tool.getCapabilities(instanceName: instanceName).wait()
        print(response)
    }
}
