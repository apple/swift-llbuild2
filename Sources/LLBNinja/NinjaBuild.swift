// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBUtil
import NIOCore

import llbuildSwift

public typealias Command = llbuildSwift.NinjaBuildStatement

public protocol NinjaValue: LLBValue {}

public class NinjaBuild {
    let manifest: NinjaManifest
    let delegate: NinjaBuildDelegate

    public enum Error: Swift.Error {
        case internalTypeError
    }

    @available(*, deprecated, renamed: "init(manifest:workingDirectory:delegate:)")
    public convenience init(manifest: String, delegate: NinjaBuildDelegate) throws {
        try self.init(manifest: manifest, workingDirectory: "/", delegate: delegate)
    }

    public init(manifest: String, workingDirectory: String, delegate: NinjaBuildDelegate) throws {
        self.manifest = try NinjaManifest(path: manifest, workingDirectory: workingDirectory)
        self.delegate = delegate
    }

    public func build<V: NinjaValue>(target: String, as: V.Type, _ ctx: Context) throws -> V {
        let engineDelegate = NinjaEngineDelegate(manifest: manifest, delegate: delegate)
        let engine = LLBEngine(delegate: engineDelegate)
        return try engine.build(key: "T" + target, as: V.self, ctx).wait()
    }
}

public protocol NinjaBuildDelegate {
    /// Build the given Ninja input.
    ///
    /// This will only be called when all inputs are available.
    func build(group: LLBFuturesDispatchGroup, path: String) -> LLBFuture<NinjaValue>
    
    /// Build the given Ninja command.
    ///
    /// This will only be called when all inputs are available.
    func build(group: LLBFuturesDispatchGroup, command: Command, inputs: [NinjaValue]) -> LLBFuture<NinjaValue>
}

private extension LLBFuture where Value == LLBValue {
    func asNinjaValue() -> LLBFuture<NinjaValue> {
        return self.flatMapThrowing { value in
            guard let ninjaValue = value as? NinjaValue else {
                throw NinjaBuild.Error.internalTypeError
            }

            return ninjaValue
        }
    }
}

enum NinjaEngineDelegateError: Error {
    case unexpectedKey(String)
    case unexpectedKeyType(String)
    case unexpectedCommandKey(String)
    case invalidKey(String)
    case commandNotFound(String)
}

private class NinjaEngineDelegate: LLBEngineDelegate {
    let manifest: NinjaManifest
    let commandMap: [String: Int]
    let delegate: NinjaBuildDelegate

    init(manifest: NinjaManifest, delegate: NinjaBuildDelegate) {
        self.manifest = manifest
        self.delegate = delegate

        // Populate the command map.
        var commandMap = [String: Int]()
        for (i,command) in self.manifest.statements.enumerated() {
            for output in command.outputs {
                commandMap[output] = i
            }
        }
        self.commandMap = commandMap
    }
    
    func lookupFunction(forKey rawKey: LLBKey, _ ctx: Context) -> LLBFuture<LLBFunction> {
        guard let key = rawKey as? String else {
            return ctx.group.next().makeFailedFuture(
                NinjaEngineDelegateError.unexpectedKeyType(String(describing: type(of: rawKey)))
            )
        }

        guard let code = key.first else {
            return ctx.group.next().makeFailedFuture(NinjaEngineDelegateError.invalidKey(key))
        }

        switch code {
            // A top-level target build request (expected to always be a valid target).
        case "T":
            // Must be a target.
            let target = String(key.dropFirst(1))
            guard let i = self.commandMap[target] else {
                return ctx.group.next().makeFailedFuture(NinjaEngineDelegateError.commandNotFound(target))
            }

            return ctx.group.next().makeSucceededFuture(
                LLBSimpleFunction { (fi, key, ctx) in
                    return fi.request("C" + String(i), ctx)
                }
            )

            // A build node.
        case "N":
            // If this is a command output, build the command (note that there
            // must be a level of indirection here, because the same command may
            // produce multiple outputs).
            let path = String(key.dropFirst(1))
            if let i = self.commandMap[path] {
                return ctx.group.next().makeSucceededFuture(
                    LLBSimpleFunction { (fi, key, ctx) in
                        return fi.request("C" + String(i), ctx)
                    }
                )
            }

            // Otherwise, it is an input file.
            return ctx.group.next().makeSucceededFuture(
                LLBSimpleFunction { (fi, key, ctx) in
                    return self.delegate.build(group: ctx.group, path: path).map { $0 as LLBValue }
                }
            )

            // A build command.
        case "C":
            let commandIndexStr = String(key.dropFirst(1))
            guard let i = Int(commandIndexStr) else {
                return ctx.group.next().makeFailedFuture(NinjaEngineDelegateError.unexpectedCommandKey(key))
            }

            return ctx.group.next().makeSucceededFuture(
                LLBSimpleFunction { (fi, key, ctx) in
                    // Get the command.
                    let command = self.manifest.statements[i]
                    // FIXME: For now, we just merge all the inputs. This isn't
                    // really in keeping with the Ninja semantics, but is strong.
                    var inputs = command.explicitInputs.map{ fi.request("N" + $0, ctx).asNinjaValue() }
                    inputs += command.implicitInputs.map{ fi.request("N" + $0, ctx).asNinjaValue() }
                    inputs += command.orderOnlyInputs.map{ fi.request("N" + $0, ctx).asNinjaValue() }
                    return LLBFuture.whenAllSucceed(inputs, on: ctx.group.next()).flatMap { inputs in
                        return self.delegate.build(group: ctx.group.next(), command: command, inputs: inputs).map { $0 as LLBValue }
                    }
                }
            )

        default:
            return ctx.group.next().makeFailedFuture(NinjaEngineDelegateError.unexpectedKey(key))
        }
    }
}
