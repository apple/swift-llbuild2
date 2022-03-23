// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import TSCUtility

public typealias FXActionExecutionEnvironment = Context

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

extension NSPredicate {
    public static var localExecutionRequirement: NSPredicate {
        NSComparisonPredicate(
            leftExpression: .init(forKeyPath: \FXActionExecutionEnvironment.isLocal),
            rightExpression: .init(forConstantValue: true),
            modifier: .direct,
            type: .equalTo
        )
    }
}

public final class FXLocalExecutor: FXExecutor {
    private let environment: FXActionExecutionEnvironment

    public init(environment: FXActionExecutionEnvironment = .init()) {
        self.environment = environment
    }

    public func canSatisfy(requirements: NSPredicate) -> Bool {
        requirements.evaluate(with: environment, substitutionVariables: nil)
    }

    public func perform<ActionType: FXAction>(
        action: ActionType,
        with executable: LLBFuture<FXExecutableID>,
        requirements: NSPredicate,
        _ ctx: Context
    ) -> LLBFuture<ActionType.ValueType> {
        action.run(ctx)
    }
}
