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

import NIO

#if os(Linux) || os(Android) || os(Windows)
    @preconcurrency import Foundation
#else
    import Foundation
#endif

public struct IllegalStreamConsumptionError: Error {
    var description: String
}

public struct ChunkSequence: AsyncSequence & Sendable {
    private let contentStream: FileContentStream?

    public init(
        takingOwnershipOfFileHandle fileHandle: FileHandle,
        group: EventLoopGroup
    ) async throws {
        // This will close the fileHandle
        let contentStream = try await fileHandle.fileContentStream(eventLoop: group.any())
        self.init(contentStream: contentStream)
    }

    internal func isSameAs(_ other: ChunkSequence) -> Bool {
        guard let myContentStream = self.contentStream else {
            return other.contentStream == nil
        }
        guard let otherContentStream = other.contentStream else {
            return self.contentStream == nil
        }
        return myContentStream.isSameAs(otherContentStream)
    }

    public func close() async throws {
        try await self.contentStream?.close()
    }

    private init(contentStream: FileContentStream?) {
        self.contentStream = contentStream
    }

    public static func makeEmptyStream() -> Self {
        return Self.init(contentStream: nil)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(self.contentStream)
    }

    public typealias Element = ByteBuffer
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = ByteBuffer
        internal typealias UnderlyingSequence = FileContentStream

        private var underlyingIterator: UnderlyingSequence.AsyncIterator?

        internal init(_ underlyingSequence: UnderlyingSequence?) {
            self.underlyingIterator = underlyingSequence?.makeAsyncIterator()
        }

        public mutating func next() async throws -> Element? {
            if self.underlyingIterator != nil {
                return try await self.underlyingIterator!.next()
            } else {
                throw IllegalStreamConsumptionError(
                    description: """
                        Either `.discard`ed, `.inherit`ed or redirected this stream to a `.fileHandle`,
                        cannot also consume it. To consume, please `.stream` it.
                        """
                )
            }
        }
    }
}
