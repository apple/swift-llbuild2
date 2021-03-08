// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

extension LLBActionConfigurationFragmentKey: LLBConfigurationFragmentKey {
    public init(additionalEnvironment: [String: String]) {
        self.additionalEnvironment = additionalEnvironment.map {
            LLBEnvironmentVariable(name: $0.key, value: $0.value)
        }.sorted { $0.name < $1.name }
    }
}

extension LLBActionConfigurationFragment: LLBConfigurationFragment {
    public init(additionalEnvironment: [LLBEnvironmentVariable]) {
        self.additionalEnvironment = additionalEnvironment
    }
}

class LLBActionConfigurationFragmentFunction: LLBBuildFunction<LLBActionConfigurationFragmentKey, LLBActionConfigurationFragment> {
    override func evaluate(
        key: LLBActionConfigurationFragmentKey,
        _ fi: LLBBuildFunctionInterface,
        _ ctx: Context
    ) -> LLBFuture<LLBActionConfigurationFragment> {
        return ctx.group.next().makeSucceededFuture(LLBActionConfigurationFragment(
            additionalEnvironment: key.additionalEnvironment)
        )
    }
}
