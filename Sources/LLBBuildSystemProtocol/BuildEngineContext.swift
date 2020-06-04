// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBCAS

/// LLBBuildEngineContext contains references to dependencies that may need to be used throught the evaluation of the
/// functions.
public protocol LLBBuildEngineContext {
    /// The dispatch group to be used as when processing the future blocks throught the build.
    var group: LLBFuturesDispatchGroup { get }

    /// The CAS database reference to use for interfacing with CAS systems.
    var db: LLBCASDatabase { get }

    /// A reference to an executor that provides action execution support.
    var executor: LLBExecutor { get }
}
