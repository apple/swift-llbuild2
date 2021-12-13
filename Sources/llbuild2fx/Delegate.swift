// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

protocol FXFunctionProvider {
    func function() -> LLBFunction
}

struct FXEngineDelegate: LLBEngineDelegate {
    enum Error: Swift.Error {
        case noFXFunctionProvider(LLBKey)
    }

    func lookupFunction(forKey key: LLBKey, _ ctx: Context) -> LLBFuture<LLBFunction> {
        guard let functionProvider = key as? FXFunctionProvider else {
            return ctx.group.next().makeFailedFuture(Error.noFXFunctionProvider(key))
        }

        let fn = functionProvider.function()

        return ctx.group.next().makeSucceededFuture(fn)
    }
}
