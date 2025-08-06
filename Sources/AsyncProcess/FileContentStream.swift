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

import AsyncAlgorithms
import DequeModule
import Foundation
import NIO

// ⚠️ IMPLEMENTATION WARNING
// - Known issues:
//   - no tests
//   - most configurations have never run
internal typealias FileContentStream = _FileContentStream
public struct _FileContentStream: AsyncSequence & Sendable {
    public typealias Element = ByteBuffer
    typealias Underlying = AsyncThrowingChannel<Element, Error>

    public final class AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = ByteBuffer

        deinit {
            // This is painful and so wrong but unfortunately, our iterators don't have a cancel signal, so the only
            // thing we can do is hope for `deinit` to be invoked :(.
            // AsyncIteratorProtocol also doesn't support `~Copyable` so we also have to make this a class.
            self.channel?.close(promise: nil)
        }

        init(underlying: Underlying.AsyncIterator, channel: (any Channel)?) {
            self.underlying = underlying
            self.channel = channel
        }

        var underlying: Underlying.AsyncIterator
        let channel: (any Channel)?

        public func next() async throws -> ByteBuffer? {
            return try await self.underlying.next()
        }
    }

    public struct IOError: Error {
        public var errnoValue: CInt

        public static func makeFromErrnoGlobal() -> IOError {
            return IOError(errnoValue: errno)
        }
    }

    private let asyncChannel: AsyncThrowingChannel<ByteBuffer, Error>
    private let channel: (any Channel)?

    internal func isSameAs(_ other: FileContentStream) -> Bool {
        return (self.asyncChannel === other.asyncChannel) && (self.channel === other.channel)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            underlying: self.asyncChannel.makeAsyncIterator(),
            channel: self.channel
        )
    }

    public func close() async throws {
        self.asyncChannel.finish()
        do {
            try await self.channel?.close().get()
        } catch ChannelError.alreadyClosed {
            // That's okay
        }
    }

    public static func makeReader(
        fileDescriptor: CInt,
        eventLoop: EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        blockingPool: NIOThreadPool = .singleton
    ) async throws -> _FileContentStream {
        try await FileContentStream(fileDescriptor: fileDescriptor, eventLoop: eventLoop, blockingPool: blockingPool)
    }

    internal init(
        fileDescriptor: CInt,
        eventLoop: EventLoop,
        blockingPool: NIOThreadPool? = nil
    ) async throws {
        var statInfo: stat = .init()
        let statError = fstat(fileDescriptor, &statInfo)
        if statError != 0 {
            throw IOError.makeFromErrnoGlobal()
        }

        let dupedFD = dup(fileDescriptor)
        let asyncChannel = AsyncThrowingChannel<ByteBuffer, Error>()
        self.asyncChannel = asyncChannel

        switch statInfo.st_mode & S_IFMT {
        case S_IFREG:
            guard let blockingPool = blockingPool else {
                throw IOError(errnoValue: EINVAL)
            }
            let fileHandle = NIOLoopBound(
                NIOFileHandle(descriptor: dupedFD),
                eventLoop: eventLoop
            )
            NonBlockingFileIO(threadPool: blockingPool)
                .readChunked(
                    fileHandle: fileHandle.value,
                    byteCount: .max,
                    allocator: ByteBufferAllocator(),
                    eventLoop: eventLoop,
                    chunkHandler: { chunk in
                        eventLoop.makeFutureWithTask {
                            await asyncChannel.send(chunk)
                        }
                    }
                )
                .whenComplete { result in
                    try! fileHandle.value.close()
                    switch result {
                    case .failure(let error):
                        asyncChannel.fail(error)
                    case .success:
                        asyncChannel.finish()
                    }
                }
            self.channel = nil
        case S_IFSOCK:
            self.channel = try await ClientBootstrap(group: eventLoop)
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(ReadIntoAsyncChannelHandler(sink: asyncChannel))
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .withConnectedSocket(dupedFD)
                .get()
        case S_IFIFO:
            self.channel = try await NIOPipeBootstrap(group: eventLoop)
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(ReadIntoAsyncChannelHandler(sink: asyncChannel))
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .takingOwnershipOfDescriptor(
                    input: dupedFD
                )
                .map { channel in
                    channel.close(mode: .output, promise: nil)
                    return channel
                }.get()
        case S_IFDIR:
            throw IOError(errnoValue: EISDIR)
        case S_IFBLK, S_IFCHR, S_IFLNK:
            throw IOError(errnoValue: EINVAL)
        default:
            // odd, but okay
            throw IOError(errnoValue: EINVAL)
        }
    }
}

private final class ReadIntoAsyncChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = Never

    private var heldUpRead = false
    private let sink: AsyncThrowingChannel<ByteBuffer, Error>
    private var state: State = .idle

    enum State {
        case idle
        case error(Error)
        case sending(Deque<ReceivedEvent>)

        mutating func enqueue(_ data: ReceivedEvent) -> ReceivedEvent? {
            switch self {
            case .idle:
                self = .sending([])
                return data
            case .error:
                return nil
            case .sending(var queue):
                queue.append(data)
                self = .sending(queue)
                return nil
            }
        }

        mutating func didSendOne() -> ReceivedEvent? {
            switch self {
            case .idle:
                preconditionFailure("didSendOne during .idle")
            case .error:
                return nil
            case .sending(var queue):
                if queue.isEmpty {
                    self = .idle
                    return nil
                } else {
                    let value = queue.removeFirst()
                    self = .sending(queue)
                    return value
                }
            }
        }

        mutating func fail(_ error: Error) {
            switch self {
            case .idle, .sending:
                self = .error(error)
            case .error:
                return
            }
        }
    }

    enum ReceivedEvent {
        case chunk(ByteBuffer)
        case finish
    }

    private var shouldRead: Bool {
        switch self.state {
        case .idle:
            return true
        case .error:
            return false
        case .sending:
            return false
        }
    }

    init(sink: AsyncThrowingChannel<ByteBuffer, Error>) {
        self.sink = sink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        if let itemToSend = self.state.enqueue(.chunk(data)) {
            self.sendOneItem(itemToSend, context: context)
        }
    }

    private func sendOneItem(_ data: ReceivedEvent, context: ChannelHandlerContext) {
        context.eventLoop.assertInEventLoop()
        assert(self.shouldRead == false, "sendOneItem in unexpected state \(self.state)")
        let eventLoop = context.eventLoop
        let sink = self.sink
        let `self` = NIOLoopBound(self, eventLoop: context.eventLoop)
        let context = NIOLoopBound(context, eventLoop: context.eventLoop)
        eventLoop.makeFutureWithTask {
            // note: We're _not_ on an EventLoop thread here
            switch data {
            case .chunk(let data):
                await sink.send(data)
            case .finish:
                sink.finish()
            }
        }.map {
            if let moreToSend = self.value.state.didSendOne() {
                self.value.sendOneItem(moreToSend, context: context.value)
            } else {
                if self.value.heldUpRead {
                    eventLoop.execute {
                        context.value.read()
                    }
                }
            }
        }.whenFailure { error in
            self.value.state.fail(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.state.fail(error)
        self.sink.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let itemToSend = self.state.enqueue(.finish) {
            self.sendOneItem(itemToSend, context: context)
        }
    }

    func read(context: ChannelHandlerContext) {
        if self.shouldRead {
            context.read()
        } else {
            self.heldUpRead = true
        }
    }
}

extension FileHandle {
    func fileContentStream(eventLoop: EventLoop) async throws -> FileContentStream {
        let asyncBytes = try await FileContentStream(fileDescriptor: self.fileDescriptor, eventLoop: eventLoop)
        try self.close()
        return asyncBytes
    }
}

extension FileContentStream {
    var lines: AsyncByteBufferLineSequence<FileContentStream> {
        return AsyncByteBufferLineSequence(
            self,
            dropTerminator: true,
            maximumAllowableBufferSize: 1024 * 1024,
            dropLastChunkIfNoNewline: false
        )
    }
}

extension AsyncSequence where Element == ByteBuffer, Self: Sendable {
    public func splitIntoLines(
        dropTerminator: Bool = true,
        maximumAllowableBufferSize: Int = 1024 * 1024,
        dropLastChunkIfNoNewline: Bool = false
    ) -> AsyncByteBufferLineSequence<Self> {
        return AsyncByteBufferLineSequence(
            self,
            dropTerminator: dropTerminator,
            maximumAllowableBufferSize: maximumAllowableBufferSize,
            dropLastChunkIfNoNewline: dropLastChunkIfNoNewline
        )
    }

    public var strings: AsyncMapSequence<Self, String> {
        return self.map { String(buffer: $0) }
    }
}

public struct AsyncByteBufferLineSequence<Base: Sendable>: AsyncSequence & Sendable
where Base: AsyncSequence, Base.Element == ByteBuffer {
    public typealias Element = ByteBuffer
    private let underlying: Base
    private let dropTerminator: Bool
    private let maximumAllowableBufferSize: Int
    private let dropLastChunkIfNoNewline: Bool

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = ByteBuffer
        private var underlying: Base.AsyncIterator
        private let dropTerminator: Bool
        private let maximumAllowableBufferSize: Int
        private let dropLastChunkIfNoNewline: Bool
        private var buffer = Buffer()

        struct Buffer {
            private var buffer: [ByteBuffer] = []
            internal private(set) var byteCount: Int = 0

            mutating func append(_ buffer: ByteBuffer) {
                self.buffer.append(buffer)
                self.byteCount += buffer.readableBytes
            }

            func allButLast() -> ArraySlice<ByteBuffer> {
                return self.buffer.dropLast()
            }

            var byteCountButLast: Int {
                return self.byteCount - (self.buffer.last?.readableBytes ?? 0)
            }

            var lastChunkView: ByteBufferView? {
                return self.buffer.last?.readableBytesView
            }

            mutating func concatenateEverything(upToLastChunkLengthToConsume lastLength: Int) -> ByteBuffer {
                var output = ByteBuffer()
                output.reserveCapacity(lastLength + self.byteCountButLast)

                var writtenBytes = 0
                for buffer in self.buffer.dropLast() {
                    writtenBytes += output.writeImmutableBuffer(buffer)
                }
                writtenBytes += output.writeImmutableBuffer(
                    self.buffer[self.buffer.endIndex - 1].readSlice(length: lastLength)!
                )
                if self.buffer.last!.readableBytes > 0 {
                    if self.buffer.count > 1 {
                        self.buffer.swapAt(0, self.buffer.endIndex - 1)
                    }
                    self.buffer.removeLast(self.buffer.count - 1)
                } else {
                    self.buffer = []
                }

                self.byteCount -= writtenBytes
                assert(self.byteCount >= 0)
                return output
            }
        }

        internal init(
            underlying: Base.AsyncIterator,
            dropTerminator: Bool,
            maximumAllowableBufferSize: Int,
            dropLastChunkIfNoNewline: Bool
        ) {
            self.underlying = underlying
            self.dropTerminator = dropTerminator
            self.maximumAllowableBufferSize = maximumAllowableBufferSize
            self.dropLastChunkIfNoNewline = dropLastChunkIfNoNewline
        }

        private mutating func deliverUpTo(
            view: ByteBufferView,
            index: ByteBufferView.Index,
            expectNewline: Bool
        ) -> ByteBuffer {
            let howMany = view.startIndex.distance(to: index) + (expectNewline ? 1 : 0)

            var output = self.buffer.concatenateEverything(upToLastChunkLengthToConsume: howMany)
            if expectNewline {
                assert(output.readableBytesView.last == UInt8(ascii: "\n"))
                assert(
                    output.readableBytesView.firstIndex(of: UInt8(ascii: "\n"))
                        == output.readableBytesView.index(before: output.readableBytesView.endIndex))
            } else {
                assert(output.readableBytesView.last != UInt8(ascii: "\n"))
                assert(!output.readableBytesView.contains(UInt8(ascii: "\n")))
            }
            if self.dropTerminator && expectNewline {
                output.moveWriterIndex(to: output.writerIndex - 1)
            }

            return output
        }

        public mutating func next() async throws -> Element? {
            while true {
                if let view = self.buffer.lastChunkView {
                    if let newlineIndex = view.firstIndex(of: UInt8(ascii: "\n")) {
                        return self.deliverUpTo(
                            view: view,
                            index: newlineIndex,
                            expectNewline: true
                        )
                    }

                    if self.buffer.byteCount > self.maximumAllowableBufferSize {
                        return self.deliverUpTo(
                            view: view,
                            index: view.endIndex,
                            expectNewline: false
                        )
                    }
                }

                if let nextBuffer = try await self.underlying.next() {
                    self.buffer.append(nextBuffer)
                } else {
                    if !self.dropLastChunkIfNoNewline, let view = self.buffer.lastChunkView, !view.isEmpty {
                        return self.deliverUpTo(
                            view: view,
                            index: view.endIndex,
                            expectNewline: false
                        )
                    } else {
                        return nil
                    }
                }
            }
        }
    }

    public init(
        _ underlying: Base, dropTerminator: Bool,
        maximumAllowableBufferSize: Int,
        dropLastChunkIfNoNewline: Bool
    ) {
        self.underlying = underlying
        self.dropTerminator = dropTerminator
        self.maximumAllowableBufferSize = maximumAllowableBufferSize
        self.dropLastChunkIfNoNewline = dropLastChunkIfNoNewline
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            underlying: self.underlying.makeAsyncIterator(),
            dropTerminator: self.dropTerminator,
            maximumAllowableBufferSize: self.maximumAllowableBufferSize,
            dropLastChunkIfNoNewline: self.dropLastChunkIfNoNewline
        )
    }
}
