// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

public protocol Expression {
    associatedtype EvaluatedType
    associatedtype Value

    func value(with object: EvaluatedType) -> Value
}

public struct ConstantExpression<EvaluatedType, Value>: Expression {
    public let value: Value

    public init(value: Value) {
        self.value = value
    }

    public func value(with object: EvaluatedType) -> Value {
        value
    }
}

public struct KeyPathExpression<EvaluatedType, Value>: Expression {
    public let keyPath: KeyPath<EvaluatedType, Value>

    public init(keyPath: KeyPath<EvaluatedType, Value>) {
        self.keyPath = keyPath
    }

    public func value(with object: EvaluatedType) -> Value {
        object[keyPath: keyPath]
    }
}
