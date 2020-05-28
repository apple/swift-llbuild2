// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2

public enum LLBBuildFunctionError: Error {
    case unexpectedKeyType(String)
}

/// An "abstract" class that represents a build function, which includes the engineContext reference and a way to
/// statically specify the types of the build keys and values.
open class LLBBuildFunction<K: LLBBuildKey, V: LLBBuildValue>: LLBFunction {
    public let engineContext: LLBBuildEngineContext

    public init(engineContext: LLBBuildEngineContext) {
        self.engineContext = engineContext
    }

    public final func compute(key: LLBKey, _ fi: LLBFunctionInterface) -> LLBFuture<LLBValue> {
        if let key = key as? K {
            return evaluate(key: key, LLBBuildFunctionInterface(fi: fi)).map { $0 }
        } else {
            return engineContext.group.next().makeFailedFuture(
                LLBBuildFunctionError.unexpectedKeyType("Expected type \(String(describing: K.self)), but got \(String(describing: type(of: key)))")
            )
        }
    }

    /// Subclasses of LLBBuildFunction should override this method to provide the actual implementation of the function.
    open func evaluate(key: K, _ fi: LLBBuildFunctionInterface) -> LLBFuture<V> {
        fatalError("This needs to be implemented by subclasses.")
    }
}

/// A wrapper for the LLBFunctionInterface build system and static type support for build functions.
public final class LLBBuildFunctionInterface {
    let fi: LLBFunctionInterface

    init(fi: LLBFunctionInterface) {
        self.fi = fi
    }

    /// Requests the value for a build key.
    func request<K: LLBBuildKey>(_ key: K) -> LLBFuture<LLBBuildValue> {
        return self.fi.request(key).map { $0 as! LLBBuildValue }
    }

    /// Requests the value for a build key.
    func request<K: LLBBuildKey, V: LLBBuildValue>(_ key: K, as valueType: V.Type = V.self) -> LLBFuture<V> {
        return self.fi.request(key).map { $0 as! V }
    }
}
