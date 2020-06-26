// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import ArgumentParser
import TSCBasic

import llbuild2
import LLBCASTool


struct CASPut: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "put",
        abstract: "Put the given file into the CAS database"
    )

    @OptionGroup()
    var options: CommonOptions

    @Argument()
    var path: AbsolutePath

    func run() throws {
        let fileSize = try localFileSystem.getFileInfo(path).size
        stderrStream <<< "importing \(path.basename), \(prettyFileSize(fileSize))\n"
        stderrStream.flush()

        let group = LLBMakeDefaultDispatchGroup()
        let ctx = Context()
        let toolOptions = self.options.toToolOptions()
        let tool = try LLBCASTool(group: group, toolOptions)
        let dataID = try tool.casPut(file: path, ctx).wait()
        print(dataID)
    }
}

struct CASGet: ParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a file from the CAS database given a data id"
    )

    @OptionGroup()
    var options: CommonOptions

    @Option()
    var id: String

    @Argument()
    var path: AbsolutePath

    func run() throws {
        guard let id = LLBDataID(string: self.id) else {
            throw StringError("Invalid data id \(self.id)")
        }

        let group = LLBMakeDefaultDispatchGroup()
        let ctx = Context()
        let toolOptions = self.options.toToolOptions()
        let tool = try LLBCASTool(group: group, toolOptions)
        try tool.casGet(id: id, to: path, ctx).wait()
    }
}

func prettyFileSize(_ size: UInt64) -> String {
    if size < 100_000 {
        return "\(size) bytes"
    } else if size < 100_000_000 {
        return String(format: "%.1f MB", Double(size) / 1_000_000)
    } else {
        return String(format: "%.1f GB", Double(size) / 1_000_000_000)
    }
}
