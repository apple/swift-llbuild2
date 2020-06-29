// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import ArgumentParser

import llbuild2
import LLBNinja

public struct NinjaBuildTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "ninja",
        abstract: "NinjaBuild tool")

    @Flag(help: "Print verbose output")
    var verbose: Bool = false

    @Option(help: "Path to the Ninja manifest file")
    var manifest: String

    @Option(help: "The name of the target to build")
    var target: String

    public init() { }

    public func run() throws {
        let dryRunDelegate = NinjaDryRunDelegate()
        let nb = try NinjaBuild(manifest: manifest, delegate: dryRunDelegate)
        let ctx = Context()
        _ = try nb.build(target: target, as: Int.self, ctx)
    }
}

extension Int: NinjaValue {}

private class NinjaDryRunDelegate: NinjaBuildDelegate {
    func build(group: LLBFuturesDispatchGroup, path: String) -> LLBFuture<NinjaValue> {
        print("build input: \(path)")
        return group.next().makeSucceededFuture(0)
    }
    
    func build(group: LLBFuturesDispatchGroup, command: Command, inputs: [NinjaValue]) -> LLBFuture<NinjaValue> {
        print("build command: \(command.command)")
        return group.next().makeSucceededFuture(0)
    }
}
