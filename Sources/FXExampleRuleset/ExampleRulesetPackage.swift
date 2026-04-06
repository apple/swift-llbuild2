// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


import llbuild2fx

public enum ExampleRulesetPackage: FXRulesetPackage {
    public typealias Config = Void

    public static func createRulesets() -> [FXRuleset] {
        return [
            FXRuleset(
                name: "ExampleRuleset",
                entrypoints: ["greeting": GreetingEntrypoint.self]
            )
        ]
    }
}
