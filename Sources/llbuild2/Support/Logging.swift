// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Logging

/// Support storing and retrieving a logger instance from a Context.
public extension Context {
    var logger: Logger? {
        get {
            guard let logger = self[ObjectIdentifier(Logger.self)] as? Logger else {
                return nil
            }
            return logger
        }
        set {
            self[ObjectIdentifier(Logger.self)] = newValue
        }
    }
}
