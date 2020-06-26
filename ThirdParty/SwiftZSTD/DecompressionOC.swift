//
//  SwiftZSTD
//
//  Created by Anatoli on 9/16/17.
//  Copyright © 2018 Apple, Inc. All rights reserved.
//
import Foundation
import llbuild2CZSTD

final class DecompressionOC: PressionOC {

    let dStream: OpaquePointer
    let outputSize: Int
    var outputData: [UInt8]

    override init?() {
        self.outputSize = ZSTD_DStreamOutSize()
        var data = [UInt8]()
        data.reserveCapacity(outputSize)
        self.outputData = data
        guard let stream = ZSTD_createDStream() else {
            return nil
        }
        self.dStream = stream
    }

    func start() -> Bool {
        guard !self.inProgress else {
            return false
        }
        ZSTD_initDStream(dStream)
        inProgress = true
        return true
    }

    /// Zero-copy decompression into a user-supplied buffer.
    @discardableResult
    func decompress<T: WriteAdvanceableBuffer>(input: UnsafeRawBufferPointer, into: inout T) -> AppendResult {
        var inBuffer = ZSTD_inBuffer(src: input.baseAddress!, size: input.count, pos: 0)

        var appendedTotal = 0
        var tryAgain = false

        // At first, the buffer is sized according to an estimate.
        var estimateOutputSize = 3 * (1 + inBuffer.size - inBuffer.pos)
        repeat {
            into.reserveWriteCapacity(estimateOutputSize)

            let errorCode = into.unsafeWrite { outPtr -> (wrote: Int, Int) in
                assert(outPtr.count >= estimateOutputSize)

                var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress!, size: outPtr.count, pos: 0)
                let rc = ZSTD_decompressStream(dStream, &outBuffer, &inBuffer)
                switch rc {
                case 0:
                    inProgress = false
                case let n where n > 0:
                    estimateOutputSize = rc
                default:
                    guard ZSTD_isError(rc) == 0 else {
                        return (wrote: 0, rc)
                    }
                    assert(estimateOutputSize > 0)
                }

                tryAgain = (outBuffer.pos == outBuffer.size) && (rc != 0)
                appendedTotal += outBuffer.pos

                return (wrote: outBuffer.pos, 0)
            }

            guard errorCode == 0 else {
                return .error(code: errorCode)
            }
        } while inBuffer.pos < inBuffer.size || tryAgain

        return .appended(count: appendedTotal)
    }

    func processData(dataIn d: Data) -> Result {
        return try! d.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) throws -> Result in
          return outputData.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Result in

            var retVal = Data()
            // Just in case, initially allocate 3 x input size for the return
            // value. Even using 0 for the initial capacity works, so it is
            // just a slight efficiency improvement.
            retVal.reserveCapacity(3 * d.count)

            var inBuffer = ZSTD_inBuffer(src: inPtr.baseAddress, size: inPtr.count, pos: 0)

            var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress!, size: outputSize, pos: 0)

            var tryAgain = false
            repeat {
                let rc = ZSTD_decompressStream(dStream, &outBuffer, &inBuffer);
                guard ZSTD_isError(rc) == 0 else {
                    return .error(code: rc)
                }

                retVal.append(outBuffer.dst!.bindMemory(to: UInt8.self, capacity: outBuffer.pos), count: outBuffer.pos)

                if rc == 0 {
                    inProgress = false
                    return .data(retVal)
                }

                tryAgain = inBuffer.pos < inBuffer.size || outBuffer.pos == outBuffer.size
                outBuffer.pos = 0
            } while tryAgain

            return .data(retVal)
          }
        }
    }

    deinit {
        ZSTD_freeDStream(dStream)
    }
}
