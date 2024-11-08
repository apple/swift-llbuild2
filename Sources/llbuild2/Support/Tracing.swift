// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Tracing
import Instrumentation
import llbuild2

struct TracerKeyType { }

/// Support storing and retrieving a tracer instance from a Context.
public extension Context {
    public var tracer: (any Tracer)? {
        get {
            guard let tracer = self[ObjectIdentifier(TracerKeyType.self)] as? (any Tracer) else {
                return nil
            }
            return tracer
        }
        set {
            self[ObjectIdentifier(TracerKeyType.self)] = newValue
        }
    }
}

