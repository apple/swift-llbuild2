// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2


extension String: LLBKey {
    public var stableHashValue: LLBDataID {
        return LLBDataID(blake3hash: self)
    }
}

public class LLBStaticFunctionDelegate: LLBEngineDelegate {
    let keyMap: [String: LLBFunction]

    public init(keyMap: [String: LLBFunction]) {
        self.keyMap = keyMap
    }

    public func lookupFunction(forKey key: LLBKey, _ ctx: Context) -> LLBFuture<LLBFunction> {
        let stringKey = key as! String
        return ctx.group.next().makeSucceededFuture(keyMap[stringKey]!)
    }
}
