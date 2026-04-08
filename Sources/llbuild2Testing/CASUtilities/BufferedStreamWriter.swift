import FXAsyncSupport
import FXCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import TSCUtility

extension FXByteBuffer {
    fileprivate var availableCapacity: Int { capacity - readableBytes }
}

/// Stream writer that buffers data before ingesting it into the CAS database.
package class LLBBufferedStreamWriter {
    private let bufferSize: Int
    private let lock = NIOConcurrencyHelpers.NIOLock()
    private var outputWriter: LLBLinkedListStreamWriter
    private var currentBuffer: FXByteBuffer
    private var currentBufferedChannel: UInt8? = nil

    package var latestID: FXFuture<FXDataID>? {
        return lock.withLock { outputWriter.latestID }
    }

    /// Creates a new buffered writer, with a default buffer size of 512kb to optimize for roundtrip read time.
    package init(_ db: any FXCASDatabase, bufferSize: Int = 1 << 19) {
        self.outputWriter = LLBLinkedListStreamWriter(db)
        self.bufferSize = bufferSize
        self.currentBuffer = FXByteBufferAllocator.init().buffer(capacity: bufferSize)
    }

    package func rebase(onto newBase: FXDataID, _ ctx: Context) {
        lock.withLock {
            outputWriter.rebase(onto: newBase, ctx)
        }
    }

    /// Writes a chunk of data into the stream. Flushes if the current buffer would overflow, or if the data to write
    /// is larger than the buffer size.
    package func write(data: FXByteBuffer, channel: UInt8, _ ctx: Context = .init()) {
        lock.withLock {
            if channel != currentBufferedChannel
                || data.readableBytes > currentBuffer.availableCapacity
            {
                _flush(ctx)
            }

            currentBufferedChannel = channel

            // If data is larger or equal than buffer size, send as is.
            if data.readableBytes >= bufferSize {
                outputWriter.append(data: data, channel: channel, ctx)
            } else {
                // data is smaller than max chunk, and if we were going to overpass the chunk size, the above check
                // would have already flushed the data, so at this point we know there's space in the buffer.
                assert(data.readableBytes <= currentBuffer.availableCapacity)
                currentBuffer.writeImmutableBuffer(data)
            }

            // If we filled the buffer, send it out.
            if currentBuffer.availableCapacity == 0 {
                _flush(ctx)
            }
        }
    }

    /// Flushes the buffer into the stream writer.
    package func flush(_ ctx: Context = .init()) {
        lock.withLock {
            _flush(ctx)
        }
    }

    /// Private implementation of flush, must be called within the lock.
    private func _flush(_ ctx: Context) {
        if currentBuffer.readableBytes > 0, let currentBufferedChannel = currentBufferedChannel {
            outputWriter.append(
                data: currentBuffer,
                channel: currentBufferedChannel, ctx
            )
            currentBuffer.clear()
        }
    }
}
