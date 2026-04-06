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

// DO NOT EDIT - Make any changes in the upstream swift-async-process package, then re-run the vendoring script.

package struct EOFSequence<Element>: AsyncSequence & Sendable {
    package typealias Element = Element

    package struct AsyncIterator: AsyncIteratorProtocol {
        package mutating func next() async throws -> Element? {
            return nil
        }
    }

    package init(of type: Element.Type = Element.self) {}

    package func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator()
    }
}
