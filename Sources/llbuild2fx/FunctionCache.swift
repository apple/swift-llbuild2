// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Logging
import NIOCore
import TSCUtility

public protocol FXKeyProperties {
    var volatile: Bool { get }

    var cachePath: String { get }
}

public protocol FXFunctionCache: Sendable {
    func get(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) -> LLBFuture<LLBDataID?>
    func update(key: FXRequestKey, props: FXKeyProperties, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void>
}
