// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

/// Protocol definition for a delegate that provides the function implementation for processing a type of build key.
public protocol LLBBuildFunctionLookupDelegate {

    /// Returns the function to use to evaluate that type of identifier, or nil if the delegate does not know how to
    /// process such build key.
    func lookupBuildFunction(for identifier: LLBBuildKeyIdentifier) -> LLBFunction?
}
