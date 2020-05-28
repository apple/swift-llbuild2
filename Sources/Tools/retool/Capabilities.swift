// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import ArgumentParser

import LLBRETool

struct Capabilities: ParsableCommand {

    @Option()
    var frontendURL: URL

    func run() throws {
        let options: LLBRETool.Options = .init(
            frontendURL: frontendURL
        )
        let tool = RETool(options)
        tool.getCapabilities()
    }
}
