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
    func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment

    func perform<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment
}

extension FXExecutor {
    func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment {
        true
    }
}

private class ContextFXExecutor {}

extension Context {
    var fxExecutor: FXExecutor! {
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
