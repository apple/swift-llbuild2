//
//  SwiftZSTD
//
//  Created by Anatoli on 9/16/17.
//  Copyright © 2018 Apple, Inc. All rights reserved.
//
import Foundation
import llbuild2CZSTD

final class CompressionOC: PressionOC {

    let cStream: OpaquePointer
    let outputSize: Int
    var outputData: [UInt8]

    override init?() {
        self.outputSize = ZSTD_CStreamOutSize()
        var data = [UInt8]()
        data.reserveCapacity(outputSize)
        self.outputData = data
        guard let stream = ZSTD_createCStream() else {
            return nil
        }
        self.cStream = stream
    }

    func start(compressionLevel: Int) -> Bool {
        guard !self.inProgress else {
            return false
        }
        ZSTD_initCStream(cStream, CInt(compressionLevel))
        inProgress = true
        return true
    }

    /// Zero-copy compression into a user-supplied buffer.
    func compress<T: WriteAdvanceableBuffer>(input: UnsafeRawBufferPointer, andFinalize: Bool, into: inout T) -> AppendResult {
        var inBuffer = ZSTD_inBuffer(src: input.baseAddress!, size: input.count, pos: 0)

        var appendedTotal = 0
        var tryAgain = false

        // At first, the buffer is sized according to an estimate.
        // The estimate for a purely random data is a few bytes more than the
        // size of the data.
        var estimatedOutputSize = 10 + inBuffer.pos
        repeat {
            into.reserveWriteCapacity(estimatedOutputSize)

            let errorCode = into.unsafeWrite { outPtr -> (wrote: Int, Int) in
                assert(outPtr.count >= estimatedOutputSize)

                var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress!, size: outPtr.count, pos: 0)

                let rc = ZSTD_compressStream(cStream, &outBuffer, &inBuffer);
                guard ZSTD_isError(rc) == 0 else {
                    return (wrote: 0, rc)
                }

                let flusher: (OpaquePointer?, UnsafeMutablePointer<ZSTD_outBuffer>?) -> Int
                if !andFinalize || inBuffer.pos < inBuffer.size {
                    flusher = ZSTD_flushStream
                } else {
                    flusher = ZSTD_endStream
                }

                let remainingBytes = flusher(cStream, &outBuffer)
                guard ZSTD_isError(remainingBytes) == 0 else {
                    return (wrote: 0, rc)
                }

                estimatedOutputSize = remainingBytes
                tryAgain = remainingBytes > 0

                appendedTotal += outBuffer.pos

                return (wrote: outBuffer.pos, 0)
            }

            guard errorCode == 0 else {
                return .error(code: errorCode)
            }
        } while inBuffer.pos < inBuffer.size || tryAgain

        return .appended(count: appendedTotal)
    }

    func processData(dataIn d: Data, andFinalize: Bool) -> Result {
        return try! d.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) throws -> Result in
          return outputData.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Result in

            // Compression output is generally somewhat less than the input.
            var retVal = Data()
            retVal.reserveCapacity(d.count)

            var inBuffer = ZSTD_inBuffer(src: inPtr.baseAddress, size: inPtr.count, pos: 0)

            var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress!, size: outputSize, pos: 0)

            repeat {
                let rc = ZSTD_compressStream(cStream, &outBuffer, &inBuffer);
                guard ZSTD_isError(rc) == 0 else {
                    return .error(code: rc)
                }

                let flusher: (OpaquePointer?, UnsafeMutablePointer<ZSTD_outBuffer>?) -> Int
                if !andFinalize || inBuffer.pos < inBuffer.size {
                    flusher = ZSTD_flushStream
                } else {
                    flusher = ZSTD_endStream
                }

                var remainingBytes: Int = 0
                repeat {
                    remainingBytes = flusher(cStream, &outBuffer)
                    guard ZSTD_isError(remainingBytes) == 0 else {
                        return .error(code: remainingBytes)
                    }
                    retVal.append(outBuffer.dst!.bindMemory(to: UInt8.self, capacity: outBuffer.pos), count: outBuffer.pos)
                    outBuffer.pos = 0
                } while remainingBytes > 0
            } while inBuffer.pos < inBuffer.size

            inProgress = !andFinalize

            return Result.data(retVal)
          }
        }
    }

    deinit {
        ZSTD_freeCStream(cStream)
    }
}
