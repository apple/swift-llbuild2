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
import llbuild2


public protocol FXExecutor {
    func perform<ActionType: FXAction>(action: ActionType, with executable: LLBFuture<FXExecutableID>, _ ctx: Context)
        -> LLBFuture<ActionType.ValueType>
}

private class ContextFXExecutor {}

extension Context {
    public var fxExecutor: FXExecutor! {
        get {
            guard let value = self[ObjectIdentifier(ContextFXExecutor.self)] as? FXExecutor else {
                return nil
            }
            return value
        }
        set {
            self[ObjectIdentifier(ContextFXExecutor.self)] = newValue
        }
    }
}

public struct FXExecutableID: FXSingleDataIDValue, FXFileID {
    public let dataID: LLBDataID
    public init(dataID: LLBDataID) {
        self.dataID = dataID
    }
}

public final class FXLocalExecutor: FXExecutor {
    public init() { }
    
    public func perform<ActionType: FXAction>(action: ActionType, with executable: LLBFuture<FXExecutableID>, _ ctx: Context)
        -> LLBFuture<ActionType.ValueType>
    {
        action.run(ctx)
    }
}
