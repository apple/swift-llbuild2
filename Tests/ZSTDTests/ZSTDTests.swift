import XCTest
import ZSTD

final class SwiftZSTDTests: XCTestCase {

    /// Enable from command-line:
    ///     ENABLE_PERFORMANCE_TESTS=true swift test
    let performanceTestsEnabled: Bool = {
        // Control heavy tests in run time rather than compile time.
        return ProcessInfo.processInfo.environment["ENABLE_PERFORMANCE_TESTS"] != nil
    }()

    /// Test normal comp compression.
    func testCompressionRoundtrip() throws {
        let processor = ZSTDProcessor(useContext: true)

        let origData = Data([3, 4, 12, 244, 32, 7, 10, 12, 13, 111, 222, 133])

        do {
            let compressedData = try processor.compressBuffer(origData, compressionLevel: 4)
            XCTAssertNotEqual(compressedData.count, 0, "Compressed to nothing, can't be")

            let decompressedData = try processor.decompressFrame(compressedData)
            XCTAssertEqual(decompressedData, origData, "Decompressed data is different from original")
        } catch ZSTDError.libraryError(let errStr) {
            XCTFail("Library error: \(errStr)")
        } catch ZSTDError.invalidCompressionLevel(let lvl){
            XCTFail("Invalid compression level: \(lvl)")
        } catch ZSTDError.inputNotContiguous {
            XCTFail("Input not contiguous.")
        } catch ZSTDError.decompressedSizeUnknown {
            XCTFail("Unknown decompressed size.")
        }
    }

    /// Test streaming, incremental compression.
    func testStreamCompression() throws {
        let stream = ZSTDStream()

        do {
            try stream.startCompression(compressionLevel: 4)
        } catch {
            XCTFail("startCompression failed: \(error)")
            throw error
        }

        let origData = Data([3, 4, 12, 244, 32, 7, 10, 12, 13, 111, 222, 133])
        let comp1: Data
        do {
            comp1 = try stream.compressionProcess(dataIn: origData[0...3])
        } catch {
            XCTFail("compressionProcess failed: \(error)")
            throw error
        }

        let comp2 = try stream.compressionFinalize(dataIn: origData[4...])

        let compressedData = comp1 + comp2

        do {
            try stream.startDecompression()
        } catch {
            XCTFail("startDecompression failed: \(error)")
            throw error
        }

        var isDone = false

        let dec1 = try stream.decompressionProcess(dataIn: compressedData[0...5], isDone: &isDone)
        XCTAssertEqual(isDone, false)
        let dec2 = try stream.decompressionProcess(dataIn: compressedData[6...], isDone: &isDone)
        XCTAssertEqual(isDone, true)

        let reconstructedData = dec1 + dec2

        XCTAssertEqual(origData, reconstructedData)
    }

    func callStreamCompressionRoundTrip(count: Int) throws {
        let stream = ZSTDStream()
        try stream.startCompression(compressionLevel: 4)
        try stream.startDecompression()

        let original = randomData(count: count)

        let compressed = try stream.compressionProcess(dataIn: original)
        var isDone = false
        let uncompressed = try stream.decompressionProcess(dataIn: compressed, isDone: &isDone)
        XCTAssertEqual(isDone, false)

        XCTAssertEqual(uncompressed, original, "Round trip doesn't match")
    }

    func testStreamCompressionRoundTrip_128K() throws {
        try callStreamCompressionRoundTrip(count: 128 * 1024)
    }

    func testStreamCompressionRoundTrip_128KPlus() throws {
        try callStreamCompressionRoundTrip(count: 128 * 1024 + 1)
    }

    func callPerformanceBlockCompression(compressionLevel level: Int) throws {
        guard performanceTestsEnabled else { return }

        let dataToCompress = randomData(count: 10 * 128 * 1024 + 1)
        let stream = ZSTDStream()
        try stream.startCompression(compressionLevel: level)

        self.measure {
            do {
                let compressed = try stream.compressionProcess(dataIn: dataToCompress)
                XCTAssertNotEqual(compressed.count, 0, "Empty compressed")
            } catch {
                XCTFail("Compression errored: \(error)")
            }
        }
    }

    func testPerformanceBlockCompression01() throws {
        try callPerformanceBlockCompression(compressionLevel: 1)
    }

    func testPerformanceBlockCompression05() throws {
        try callPerformanceBlockCompression(compressionLevel: 5)
    }

    func testPerformanceBlockCompression10() throws {
        try callPerformanceBlockCompression(compressionLevel: 10)
    }

    func testPerformanceBlockCompression20() throws {
        try callPerformanceBlockCompression(compressionLevel: 20)
    }

    func callPerformanceStreamCompression(compressionLevel level: Int) throws {
        guard performanceTestsEnabled else { return }

        let dataToCompress = Array(randomData(count: 10 * 128 * 1024 + 1))
        let stream = ZSTDStream()
        try stream.startCompression(compressionLevel: level)

        self.measure {
            do {
                var compressed = [UInt8]()
                let appended = try dataToCompress.withUnsafeBytes { inBuffer in
                    try stream.compress(input: inBuffer, into: &compressed)
                }
                XCTAssertNotEqual(compressed.count, 0, "Empty compressed")
                XCTAssertEqual(compressed.count, appended)
            } catch {
                XCTFail("Compression errored: \(error)")
            }
        }
    }

    func testPerformanceStreamCompression01() throws {
        try callPerformanceStreamCompression(compressionLevel: 1)
    }

    func testSequentialFrames() throws {
        let stream = ZSTDStream()
        try stream.startCompression(compressionLevel: 1)
        try stream.startDecompression()

        let original = randomData(count: 100)

        for n in (1...5) {
            var isDone = false
            let compressed = try stream.compressionProcess(dataIn: original)
            let uncompressed = try stream.decompressionProcess(dataIn: compressed, isDone: &isDone)
            XCTAssertEqual(isDone, false)
            XCTAssertEqual(uncompressed, original, "Round trip doesn't match")

            // The first frame could result in expansion
            XCTAssert(n > 1 || (compressed.count > (original.count / 2)))
            // The subsequent frames should result in compaction
            XCTAssert(n == 1 || (compressed.count < (original.count / 4)), "n=\(n), compressed.count=\(compressed.count), original.count=\(original.count)")
        }
    }

    func testPassThroughAPI() throws {
        let stream = ZSTDStream()
        try stream.startCompression(compressionLevel: 1)
        try stream.startDecompression()

        let original = Array(randomData(count: 100))

        for _ in (1...5) {
            var compressed = [UInt8]()
            var decompressed = [UInt8]()

            let appendedCompr = try original.withUnsafeBytes { inBuffer in
                try stream.compress(input: inBuffer, into: &compressed)
            }
            XCTAssertEqual(compressed.count, appendedCompr)

            var isDone = false
            let appendedDecompr = try compressed.withUnsafeBytes { inBuffer in
                try stream.decompress(input: inBuffer, into: &decompressed, isDone: &isDone)
            }
            XCTAssertEqual(isDone, false)
            XCTAssertEqual(decompressed.count, appendedDecompr)

            XCTAssertEqual(decompressed, original)
        }
    }

    private func randomData(count: Int) -> Data {
        var data = Data()
        for _ in 1...count {
            data.append(UInt8(random() & 0xff))
        }
        return data
    }

    private func random() -> Int {
#if os(macOS)
        return Int(arc4random())
#else
        return Int(UInt32(bitPattern: rand()))
#endif
    }

    static var allTests = [
        ("testCompressionRoundtrip", testCompressionRoundtrip),
        ("testStreamCompression", testStreamCompression),
        ("testStreamCompressionRoundTrip_128K", testStreamCompressionRoundTrip_128K),
        ("testStreamCompressionRoundTrip_128KPlus", testStreamCompressionRoundTrip_128KPlus),
        ("testSequentialFrames", testSequentialFrames),
        ("testPassThroughAPI", testPassThroughAPI),
        ("testPerformanceBlockCompression01", testPerformanceBlockCompression01),
        ("testPerformanceBlockCompression05", testPerformanceBlockCompression05),
        ("testPerformanceBlockCompression10", testPerformanceBlockCompression10),
        ("testPerformanceBlockCompression20", testPerformanceBlockCompression20),
        ("testPerformanceStreamCompression01", testPerformanceStreamCompression01),
    ]
}

/// - WARNING:
/// We can't properly implement zero-copy using this mechanism on Arrays,
/// since Arrays don't allow advancing the write pointer without copying the
/// elements somewhere. So, we allocate and copy through a temporary here.
/// A more advanced buffer implementations allow reserving and advancing write
/// pointer. Zero copy would work as intended with those implementations.
extension Array: WriteAdvanceableBuffer where Element == UInt8 {
    public mutating func reserveWriteCapacity(_ count: Int) {
        self.reserveCapacity(self.count + count)
    }

    public mutating func unsafeWrite<R>(_ writeCallback: (UnsafeMutableRawBufferPointer) -> (wrote: Int, R)) -> R {
        let writeCapacity = self.capacity - self.count

        var tmp = [UInt8](repeating: 0, count: writeCapacity)

        let (wrote, retVal) = tmp.withUnsafeMutableBytes { bufPtr -> (Int, R) in
            precondition(bufPtr.count >= writeCapacity)
            let (wrote, retVal) = writeCallback(bufPtr)
            precondition(wrote >= 0)
            precondition(wrote <= writeCapacity, "wrote=\(wrote), writeCapacity=\(writeCapacity)")
            return (wrote, retVal)
        }

        self.append(contentsOf: tmp[0..<wrote])
        return retVal
    }
}
