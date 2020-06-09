// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import ArgumentParser
import GRPC
import TSCBasic

import LLBCASTool
import LLBSupport


struct Capabilities: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        abstract: "Get the server capabilities of the remote server"
    )

    @OptionGroup()
    var options: CommonOptions

    func run() throws {
        let group = LLBMakeDefaultDispatchGroup()
        let toolOptions = self.options.toToolOptions()
        let tool = try LLBCASTool(group: group, toolOptions)

        let response = try tool.getCapabilities().wait()
        print(response)
    }
}

