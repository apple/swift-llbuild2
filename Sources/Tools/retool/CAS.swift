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
import llbuild2
import GRPC
import LLBRETool

struct CAS: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        abstract: "Perform operations of the CAS database",
        subcommands: [
            CASGet.self,
            CASPut.self,
        ]
    )
}

struct CASPut: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "put",
        abstract: "Put the given file into the CAS database"
    )

    @OptionGroup()
    var options: Options

    @Argument()
    var path: AbsolutePath

    func run() throws {
        let toolOptions = self.options.toToolOptions()
        let tool = RETool(toolOptions)
        try tool.casPut(file: path)
    }
}

struct CASGet: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a file from the CAS database given a data id"
    )

    @OptionGroup()
    var options: Options

    @Option()
    var id: String

    @Argument()
    var path: AbsolutePath

    func run() throws {
        guard let id = LLBDataID(string: self.id) else {
            throw StringError("Invalid data id \(self.id)")
        }

        let toolOptions = self.options.toToolOptions()
        let tool = RETool(toolOptions)
        try tool.casGet(id: id, to: path)
    }
}
