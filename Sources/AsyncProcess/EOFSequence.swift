//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public struct EOFSequence<Element>: AsyncSequence & Sendable {
    public typealias Element = Element

    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> Element? {
            return nil
        }
    }

    public init(of type: Element.Type = Element.self) {}

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator()
    }
}
