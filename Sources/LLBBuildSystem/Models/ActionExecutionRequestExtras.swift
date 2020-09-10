// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

extension LLBActionExecutionRequestExtras {
    init(mnemonic: String, description: String, owner: LLBLabel?) {
        self = Self.with {
            $0.mnemonic = mnemonic
            $0.description_p = description
            if let owner = owner {
                $0.owner = owner
            }
        }
    }
}
