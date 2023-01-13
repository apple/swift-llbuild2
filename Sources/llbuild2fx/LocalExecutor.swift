// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOCore

extension FXActionExecutionEnvironment {
    private final class ContextKey {}
    private static let key = ContextKey()
    public var isLocal: Bool {
        get {
            guard let value = self[ObjectIdentifier(Self.key)] as? Bool else {
                return false
            }

            return value
        }
        set {
            self[ObjectIdentifier(Self.key)] = newValue
        }
    }
}

extension FXActionExecutionEnvironment {
    public static var local: EqualityPredicate<KeyPathExpression<Self, Bool>, ConstantExpression<Self, Bool>> {
        EqualityPredicate(
            leftExpression: KeyPathExpression(keyPath: \FXActionExecutionEnvironment.isLocal),
            rightExpression: ConstantExpression(value: true)
        )
    }
}

public final class FXLocalExecutor: FXExecutor {
    private let environment: FXActionExecutionEnvironment

    public init(environment: FXActionExecutionEnvironment = .init()) {
        var env = environment
        env.isLocal = true
        self.environment = env
    }

    public func canSatisfy<P: Predicate>(requirements: P) -> Bool where P.EvaluatedType == FXActionExecutionEnvironment {
        requirements.evaluate(with: environment)
    }

    public func perform<ActionType: FXAction, P: Predicate>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>,
        requirements: P,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> where P.EvaluatedType == FXActionExecutionEnvironment {
        action.run(ctx)
    }
}
