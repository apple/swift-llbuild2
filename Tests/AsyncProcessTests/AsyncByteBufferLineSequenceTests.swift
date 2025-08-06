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

import AsyncProcess
import Foundation
import NIO
import XCTest

final class AsyncByteBufferLineSequenceTests: XCTestCase {
    func testJustManyNewlines() async throws {
        for n in 0..<100 {
            let inputs: [ByteBuffer] = [ByteBuffer(repeating: UInt8(ascii: "\n"), count: n)]
            let lines = try await Array(inputs.async.splitIntoLines().strings)
            XCTAssertEqual(Array(repeating: "", count: n), lines)
        }
    }

    func testJustOneNewlineAtATime() async throws {
        for n in 0..<100 {
            let inputs: [ByteBuffer] = Array(repeating: ByteBuffer(integer: UInt8(ascii: "\n")), count: n)
            let lines = try await Array(inputs.async.splitIntoLines().strings)
            XCTAssertEqual(Array(repeating: "", count: n), lines)
        }
    }

    func testManyChunksNoNewlineDeliveringLastChunk() async throws {
        for n in 1..<100 {
            let inputs: [ByteBuffer] = [ByteBuffer(repeating: 0, count: n)]
            let lines = try await Array(inputs.async.splitIntoLines().strings)
            XCTAssertEqual([String(repeating: "\0", count: n)], lines)
        }
    }

    func testManyChunksNoNewlineNotDeliveringLastChunk() async throws {
        for n in 0..<100 {
            let inputs: [ByteBuffer] = [ByteBuffer(repeating: 0, count: n)]
            let lines = try await Array(inputs.async.splitIntoLines(dropLastChunkIfNoNewline: true).strings)
            XCTAssertEqual([], lines)
        }
    }

    func testOverlyLongLineIsSplit() async throws {
        var inputs = Array(repeating: ByteBuffer(integer: UInt8(0)), count: 10)
        inputs.append(ByteBuffer(integer: UInt8(ascii: "\n")))
        let lines = try await Array(
            inputs.async.splitIntoLines(
                maximumAllowableBufferSize: 3,
                dropLastChunkIfNoNewline: true
            ).strings)
        XCTAssertEqual(["\0\0\0\0", "\0\0\0\0", "\0\0"], lines)
    }

    func testOverlyLongLineIsSplitByDefault() async throws {
        var inputs = [ByteBuffer(repeating: UInt8(0), count: 1024 * 1024 - 2)]  // almost at the limit
        inputs.append(ByteBuffer(integer: UInt8(ascii: "\0")))
        inputs.append(ByteBuffer(integer: UInt8(ascii: "\0")))  // hitting the limit
        inputs.append(ByteBuffer(integer: UInt8(ascii: "\0")))  // over the limit
        inputs.append(ByteBuffer(integer: UInt8(ascii: "\n")))  // too late
        let lines = try await Array(
            inputs.async.splitIntoLines(
                dropTerminator: false,
                dropLastChunkIfNoNewline: true
            ).strings)
        XCTAssertEqual([String(repeating: "\0", count: 1024 * 1024 + 1), "\n"], lines)
    }
}
