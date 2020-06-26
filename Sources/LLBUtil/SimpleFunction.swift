// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2


public class LLBSimpleFunction: LLBFunction {
    let action: (_ fi: LLBFunctionInterface, _ key: LLBKey, _ ctx: Context) -> LLBFuture<LLBValue>

    public init(action: @escaping (_ fi: LLBFunctionInterface, _ key: LLBKey, _ ctx: Context) -> LLBFuture<LLBValue>) {
        self.action = action
    }

    public func compute(key: LLBKey, _ fi: LLBFunctionInterface, _ ctx: Context) -> LLBFuture<LLBValue> {
        return action(fi, key, ctx)
    }
}
