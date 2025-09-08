// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public protocol Predicate {
    associatedtype EvaluatedType
    func evaluate(with object: EvaluatedType) -> Bool
}

public struct AnyPredicate<EvaluatedType>: Predicate {
    public let predicate: Any
    private let evaluator: (EvaluatedType) -> Bool

    public init<P: Predicate>(_ predicate: P) where P.EvaluatedType == EvaluatedType {
        self.predicate = predicate
        evaluator = predicate.evaluate
    }

    public func evaluate(with object: EvaluatedType) -> Bool {
        evaluator(object)
    }
}

public struct ConstantPredicate<EvaluatedType>: Predicate {
    public let value: Bool

    public init(value: Bool) {
        self.value = value
    }

    public func evaluate(with object: EvaluatedType) -> Bool {
        value
    }
}

public struct EqualityPredicate<LHS, RHS>: Predicate
where
    LHS: Expression,
    RHS: Expression,
    LHS.EvaluatedType == RHS.EvaluatedType,
    LHS.Value == RHS.Value,
    LHS.Value: Equatable
{
    public let leftExpression: LHS
    public let rightExpression: RHS

    public init(leftExpression lhs: LHS, rightExpression rhs: RHS) {
        leftExpression = lhs
        rightExpression = rhs
    }

    public func evaluate(with object: LHS.EvaluatedType) -> Bool {
        let lhs = leftExpression.value(with: object)
        let rhs = rightExpression.value(with: object)

        return lhs == rhs
    }
}

public struct NotPredicate<P: Predicate>: Predicate {
    public let subpredicate: P

    public init(subpredicate: P) {
        self.subpredicate = subpredicate
    }

    public func evaluate(with object: P.EvaluatedType) -> Bool {
        !subpredicate.evaluate(with: object)
    }
}

public struct AndPredicate<EvaluatedType>: Predicate {
    public let subpredicates: [AnyPredicate<EvaluatedType>]

    public init(subpredicates: [AnyPredicate<EvaluatedType>]) {
        self.subpredicates = subpredicates
    }

    public func evaluate(with object: EvaluatedType) -> Bool {
        subpredicates.reduce(true) {
            $0 && $1.evaluate(with: object)
        }
    }
}

public struct OrPredicate<EvaluatedType>: Predicate {
    public let subpredicates: [AnyPredicate<EvaluatedType>]

    public init(subpredicates: [AnyPredicate<EvaluatedType>]) {
        self.subpredicates = subpredicates
    }

    public func evaluate(with object: EvaluatedType) -> Bool {
        subpredicates.reduce(false) {
            $0 || $1.evaluate(with: object)
        }
    }
}
