// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Logging
import NIOCore
import TSCUtility

public protocol FXKeyProperties: Sendable {
    var volatile: Bool { get }

    var cachePath: String { get }
}

public protocol FXFunctionCache<DataID>: Sendable {
    associatedtype DataID: FXDataIDProtocol = FXDataID
    func get(key: FXRequestKey, props: FXKeyProperties, _ ctx: Context) -> FXFuture<DataID?>
    func update(key: FXRequestKey, props: FXKeyProperties, value: DataID, _ ctx: Context) -> FXFuture<Void>
}
