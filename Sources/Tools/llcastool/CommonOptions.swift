// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import ArgumentParser
import Foundation
import LLBCASTool
import TSCUtility

struct CommonOptions: ParsableArguments {
    @Option(help: "The CAS database URL to use")
    var url: Foundation.URL
}

extension CommonOptions {
    func toToolOptions() -> LLBCASToolOptions {
        return LLBCASToolOptions(
            url: url
        )
    }
}
