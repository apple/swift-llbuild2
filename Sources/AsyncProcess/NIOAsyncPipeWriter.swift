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

import Foundation
import NIO

struct NIOAsyncPipeWriter<Chunks: AsyncSequence & Sendable> where Chunks.Element == ByteBuffer {
    static func sinkSequenceInto(
        _ chunks: Chunks,
        takingOwnershipOfFD fd: CInt,
        ignoreWriteErrors: Bool,
        eventLoop: EventLoop
    ) async throws {
        let channel = try await NIOPipeBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: false)
            .takingOwnershipOfDescriptor(
                output: fd
            ).get()
        channel.close(mode: .input, promise: nil)
        return try await asyncDo {
            try await withTaskCancellationHandler {
                for try await chunk in chunks {
                    do {
                        try await channel.writeAndFlush(chunk).get()
                    } catch {
                        if !ignoreWriteErrors {
                            throw error
                        }
                        break
                    }
                }
            } onCancel: {
                channel.close(promise: nil)
            }
        } finally: { _ in
            do {
                try await channel.close()
            } catch ChannelError.alreadyClosed {
                // ok
            }
        }
    }
}
