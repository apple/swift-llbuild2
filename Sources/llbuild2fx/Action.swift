// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCUtility
import TSFCAS
import TSFFutures


public protocol FXAction: FXValue {
    associatedtype ValueType: FXValue

    static var version: Int { get }

    func run(_ ctx: Context) -> LLBFuture<ValueType>
}

extension FXAction {
    public static var version: Int { 0 }
}
