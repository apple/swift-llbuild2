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
import AsyncProcess
import Atomics
import Logging
import NIO
import NIOConcurrencyHelpers
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    @preconcurrency import Musl
#elseif canImport(Glibc)
    @preconcurrency import Glibc
#elseif canImport(WASILibc)
    @preconcurrency import WASILibc
#elseif canImport(Bionic)
    @preconcurrency import Bionic
#elseif canImport(Android)
    @preconcurrency import Android
#else
    #error("unknown libc, please fix")
#endif


final class IntegrationTests: XCTestCase {
    private var group: EventLoopGroup!
    private var logger: Logger!
    private var highestFD: CInt?

    func testTheBasicsWork() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh", ["-c", "exit 0"],
            standardInput: EOFSequence(),
            logger: self.logger
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await chunk in await merge(exe.standardOutput, exe.standardError) {
                    XCTFail("unexpected output: \(String(buffer: chunk)): \(chunk)")
                }
            }
            let result = try await exe.run()
            XCTAssertEqual(.exit(CInt(0)), result)
        }
    }

    func testExitCodesWork() async throws {
        for exitCode in (UInt8.min...UInt8.max) {
            let exe = ProcessExecutor(
                group: self.group,
                executable: "/bin/sh", ["-c", "exit \(exitCode)"],
                standardInput: EOFSequence(),
                logger: self.logger
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await chunk in await merge(exe.standardOutput, exe.standardError) {
                        XCTFail("unexpected output: \(String(buffer: chunk)): \(chunk)")
                    }
                }

                let result = try await exe.run()
                XCTAssertEqual(.exit(CInt(exitCode)), result)
                XCTAssertEqual(Int(exitCode), result.asShellExitCode)
                XCTAssertEqual(Int(exitCode), result.asPythonExitCode)
            }
        }
    }

    #if ASYNC_PROCESS_ENABLE_TESTS_WITH_PLATFORM_ASSUMPTIONS
        // The test below won't work on many shells ("/bin/sh: 1: exit: Illegal number: -999999999")
        func testWeirdExitCodesWork() async throws {
            for (exitCode, expected) in [(-1, 255), (-2, 254), (256, 0), (99_999_999, 255), (-999_999_999, 1)] {
                let exe = ProcessExecutor(
                    group: self.group,
                    executable: "/bin/sh", ["-c", "exit \(exitCode)"],
                    standardInput: EOFSequence(),
                    logger: self.logger
                )
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await chunk in await merge(exe.standardOutput, exe.standardError) {
                            XCTFail("unexpected output: \(String(buffer: chunk)): \(chunk)")
                        }
                    }

                    let result = try await exe.run()
                    XCTAssertEqual(.exit(CInt(expected)), result)
                    XCTAssertEqual(Int(expected), result.asShellExitCode)
                    XCTAssertEqual(Int(expected), result.asPythonExitCode)
                }
            }
        }
    #endif

    func testSignalsWork() async throws {
        let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
        for signal in signalsToTest {
            let exe = ProcessExecutor(
                group: self.group,
                executable: "/bin/sh", ["-c", "kill -\(signal) $$"],
                standardInput: EOFSequence(),
                logger: self.logger
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await chunk in await merge(exe.standardOutput, exe.standardError) {
                        XCTFail("unexpected output: \(String(buffer: chunk)): \(chunk)")
                    }
                }

                let result = try await exe.run()
                XCTAssertEqual(.signal(CInt(signal)), result)
                XCTAssertEqual(128 + Int(signal), result.asShellExitCode)
                XCTAssertEqual(-Int(signal), result.asPythonExitCode)
            }
        }
    }

    func testStreamingInputAndOutputWorks() async throws {
        let input = AsyncStream.justMakeIt(elementType: ByteBuffer.self)
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/cat", ["-nu"],  // sh", ["-c", "while read -r line; do echo $line; done"],
            standardInput: input.consumer,
            logger: self.logger
        )
        try await withThrowingTaskGroup(of: ProcessExitReason?.self) { group in
            group.addTask {
                var lastLine: String? = nil
                for try await line in await exe.standardOutput.splitIntoLines(dropTerminator: false) {
                    if line.readableBytes > 72 {
                        lastLine = String(buffer: line)
                        break
                    }
                    input.producer.yield(line)
                }
                XCTAssertEqual(
                    "    10\t     9\t     8\t     7\t     6\t     5\t     4\t     3\t     2\t     1\tGO\n",
                    lastLine
                )
                return nil
            }

            group.addTask {
                for try await chunk in await exe.standardError {
                    XCTFail("unexpected output: \(String(buffer: chunk)): \(chunk)")
                }
                return nil
            }

            group.addTask {
                return try await exe.run()
            }

            input.producer.yield(ByteBuffer(string: "GO\n"))

            // The stdout-reading task will exit first (the others will only return when we explicitly cancel because
            // the sub process would keep going forever).
            let stdoutReturn = try await group.next()
            var totalTasksReturned = 1
            XCTAssertEqual(.some(nil), stdoutReturn)
            group.cancelAll()

            while let furtherReturn = try await group.next() {
                totalTasksReturned += 1
                switch furtherReturn {
                case .some(let result):
                    // the `exe.run()` task
                    XCTAssert(.signal(SIGKILL) == result || .exit(0) == result)
                case .none:
                    // stderr task
                    ()
                }
            }
            XCTAssertEqual(3, totalTasksReturned)
        }
    }

    func testAbsorbing1MBOfDevZeroWorks() async throws {
        let totalAmountInBytes = 1024 * 1024
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            [
                "-c",
                // spawn two `dd`s that output 1 MiB of zeros (but no diagnostics output). One bunch of zeroes will
                // go to stdout, the other one to stderr.
                "/bin/dd     2>/dev/null bs=\(totalAmountInBytes) count=1 if=/dev/zero; "
                    + "/bin/dd >&2 2>/dev/null bs=\(totalAmountInBytes) count=1 if=/dev/zero; ",
            ],
            standardInput: EOFSequence(),
            logger: self.logger
        )
        try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
            group.addTask {
                var accumulation = ByteBuffer()
                accumulation.reserveCapacity(totalAmountInBytes)

                for try await chunk in await exe.standardOutput {
                    accumulation.writeImmutableBuffer(chunk)
                }

                return accumulation
            }

            group.addTask {
                var accumulation = ByteBuffer()
                accumulation.reserveCapacity(totalAmountInBytes)

                for try await chunk in await exe.standardError {
                    accumulation.writeImmutableBuffer(chunk)
                }

                return accumulation
            }

            let result = try await exe.run()

            // once for stdout, once for stderr
            let stream1 = try await group.next()
            let stream2 = try await group.next()
            XCTAssertEqual(ByteBuffer(repeating: 0, count: totalAmountInBytes), stream1)
            XCTAssertEqual(ByteBuffer(repeating: 0, count: totalAmountInBytes), stream2)

            XCTAssertEqual(.exit(0), result)
        }
    }

    func testInteractiveShell() async throws {
        let input = AsyncStream.justMakeIt(elementType: ByteBuffer.self)
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh", [],
            standardInput: input.consumer,
            logger: self.logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var allOutput: [String] = []
                for try await (stream, line) in merge(
                    await exe.standardOutput.splitIntoLines(dropTerminator: true).map { ("stdout", $0) },
                    await exe.standardError.splitIntoLines(dropTerminator: true).map { ("stderr", $0) }
                ) {
                    let formattedOutput = "\(String(buffer: line)) [\(stream)]"
                    allOutput.append(formattedOutput)
                }

                XCTAssertEqual(
                    [
                        ("hello stderr [stderr]"),
                        ("hello stdout [stdout]"),
                    ],
                    allOutput.sorted()
                )
            }

            group.addTask {
                let result = try await exe.run()
                XCTAssertEqual(.exit(0), result)
            }

            input.producer.yield(ByteBuffer(string: "echo hello stdout\n"))
            input.producer.yield(ByteBuffer(string: "echo >&2 hello stderr\n"))
            input.producer.yield(ByteBuffer(string: "exit 0\n"))
            input.producer.finish()

            try await group.waitForAll()
        }
    }

    func testEnvironmentVariables() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo $MY_VAR"],
            environment: ["MY_VAR": "value of my var"],
            standardInput: EOFSequence(),
            logger: self.logger
        )
        let all = try await exe.runGetAllOutput()
        XCTAssertEqual(.exit(0), all.exitReason)
        XCTAssertEqual("value of my var\n", String(buffer: all.standardOutput))
        XCTAssertEqual("", String(buffer: all.standardError))
    }

    func testSimplePipe() async throws {
        self.logger.logLevel = .debug
        let echo = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo foo;"],
            standardInput: EOFSequence(),
            standardError: .discard,
            logger: self.logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await echo.run().throwIfNonZero()
            }
            group.addTask { [elg = self.group!, logger = self.logger!] in
                let echoOutput = await echo.standardOutput

                let sed = ProcessExecutor(
                    group: elg,
                    executable: "/usr/bin/tr",
                    ["[:lower:]", "[:upper:]"],
                    standardInput: echoOutput,
                    logger: logger
                )
                let output = try await sed.runGetAllOutput()
                XCTAssertEqual(String(buffer: output.standardOutput), "FOO\n")
            }
            try await group.waitForAll()
        }
    }

    func testStressTestVeryLittleOutput() async throws {
        for _ in 0..<128 {
            let exe = ProcessExecutor(
                group: self.group,
                executable: "/bin/sh",
                ["-c", "echo x; echo >&2 y;"],
                standardInput: EOFSequence(),
                logger: self.logger
            )
            let all = try await exe.runGetAllOutput()
            XCTAssertEqual(.exit(0), all.exitReason)
            XCTAssertEqual("x\n", String(buffer: all.standardOutput))
            XCTAssertEqual("y\n", String(buffer: all.standardError))
        }
    }

    func testOutputWithoutNewlinesThatIsSplitIntoLines() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "/bin/echo -n x; /bin/echo >&2 -n y"],
            standardInput: EOFSequence(),
            logger: self.logger
        )
        try await withThrowingTaskGroup(of: (String, ByteBuffer)?.self) { group in
            group.addTask {
                try await exe.run().throwIfNonZero()
                return nil
            }
            group.addTask {
                var things: [ByteBuffer] = []
                for try await chunk in await exe.standardOutput.splitIntoLines() {
                    things.append(chunk)
                }
                XCTAssertEqual(1, things.count)
                return ("stdout", things.first.flatMap { $0 } ?? ByteBuffer(string: "n/a"))
            }
            group.addTask {
                var things: [ByteBuffer?] = []
                for try await chunk in await exe.standardError.splitIntoLines() {
                    things.append(chunk)
                }
                XCTAssertEqual(1, things.count)
                return ("stderr", things.first.flatMap { $0 } ?? ByteBuffer(string: "n/a"))
            }

            let everything = try await Array(group).sorted { l, r in
                guard let l = l else {
                    return true
                }
                guard let r = r else {
                    return false
                }
                return l.0 < r.0
            }
            XCTAssertEqual(
                [nil, "stderr", "stdout"],
                everything.map { $0?.0 }
            )

            XCTAssertEqual(
                [nil, ByteBuffer(string: "y"), ByteBuffer(string: "x")],
                everything.map { $0?.1 }
            )
        }
    }

    func testDiscardingStdoutWorks() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/dd",
            ["if=/dev/zero", "bs=\(1024*1024)", "count=1024", "status=none"],
            standardInput: EOFSequence(),
            standardOutput: .discard,
            standardError: .stream,
            logger: self.logger
        )
        async let stderr = exe.standardError.pullAllOfIt()
        try await exe.run().throwIfNonZero()
        let stderrBytes = try await stderr
        XCTAssertEqual(ByteBuffer(), stderrBytes)
    }

    func testDiscardingStderrWorks() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024*1024) count=1024 status=none; echo OK"],
            standardInput: EOFSequence(),
            standardOutput: .stream,
            standardError: .discard,
            logger: self.logger
        )
        async let stdout = exe.standardOutput.pullAllOfIt()
        try await exe.run().throwIfNonZero()
        let stdoutBytes = try await stdout
        XCTAssertEqual(ByteBuffer(string: "OK\n"), stdoutBytes)
    }

    func testStdoutToFileWorks() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
        }

        let file = tempDir.appendingPathComponent("file")

        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/dd",
            ["if=/dev/zero", "bs=\(1024*1024)", "count=3", "status=none"],
            standardInput: EOFSequence(),
            standardOutput: .fileDescriptor(
                takingOwnershipOf: try .open(
                    .init(file.path.removingPercentEncoding!),
                    .writeOnly,
                    options: .create,
                    permissions: [.ownerRead, .ownerWrite]
                )),
            standardError: .stream,
            logger: self.logger
        )
        async let stderr = exe.standardError.pullAllOfIt()
        try await exe.run().throwIfNonZero()
        let stderrBytes = try await stderr
        XCTAssertEqual(Data(repeating: 0, count: 3 * 1024 * 1024), try Data(contentsOf: file))
        XCTAssertEqual(ByteBuffer(), stderrBytes)
    }

    func testStderrToFileWorks() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
        }

        let file = tempDir.appendingPathComponent("file")

        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024*1024) count=3 status=none; echo OK"],
            standardInput: EOFSequence(),
            standardOutput: .stream,
            standardError: .fileDescriptor(
                takingOwnershipOf: try! .open(
                    .init(file.path.removingPercentEncoding!),
                    .writeOnly,
                    options: .create,
                    permissions: [.ownerRead, .ownerWrite]
                )),
            logger: self.logger
        )
        async let stdout = exe.standardOutput.pullAllOfIt()
        try await exe.run().throwIfNonZero()
        let stdoutBytes = try await stdout
        XCTAssertEqual(ByteBuffer(string: "OK\n"), stdoutBytes)
        XCTAssertEqual(Data(repeating: 0, count: 3 * 1024 * 1024), try Data(contentsOf: file))
    }

    func testInheritingStdoutAndStderrWork() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo this is stdout; echo >&2 this is stderr"],
            standardInput: EOFSequence(),
            standardOutput: .inherit,
            standardError: .inherit,
            logger: self.logger
        )
        try await exe.run().throwIfNonZero()
    }

    func testDiscardingAndConsumingOutputYieldsAnError() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo this is stdout; echo >&2 this is stderr"],
            standardInput: EOFSequence(),
            standardOutput: .discard,
            standardError: .discard,
            logger: self.logger
        )
        try await exe.run().throwIfNonZero()
        var stdoutIterator = await exe.standardOutput.makeAsyncIterator()
        var stderrIterator = await exe.standardError.makeAsyncIterator()
        do {
            _ = try await stdoutIterator.next()
            XCTFail("expected this to throw")
        } catch is IllegalStreamConsumptionError {
            // OK
        }
        do {
            _ = try await stderrIterator.next()
            XCTFail("expected this to throw")
        } catch is IllegalStreamConsumptionError {
            // OK
        }
    }

    func testStressTestDiscardingOutput() async throws {
        for _ in 0..<128 {
            let exe = ProcessExecutor(
                group: self.group,
                executable: "/bin/sh",
                [
                    "-c",
                    "/bin/dd if=/dev/zero bs=\(1024*1024) count=1; /bin/dd >&2 if=/dev/zero bs=\(1024*1024) count=1;",
                ],
                standardInput: EOFSequence(),
                standardOutput: .discard,
                standardError: .discard,
                logger: self.logger
            )
            try await exe.run().throwIfNonZero()
        }
    }

    func testLogOutputToMetadata() async throws {
        let sharedRecorder = LogRecorderHandler()
        var recordedLogger = Logger(label: "recorder", factory: { label in sharedRecorder })
        recordedLogger.logLevel = .info  // don't give us the normal messages
        recordedLogger[metadataKey: "yo"] = "hey"

        try await ProcessExecutor.runLogOutput(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8;"],
            standardInput: EOFSequence(),
            logger: recordedLogger,
            logConfiguration: OutputLoggingSettings(logLevel: .critical, to: .metadata(logMessage: "msg", key: "key"))
        ).throwIfNonZero()
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.level == .critical })
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.message == "msg" })
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["key"] != nil })
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["yo"] == "hey" })
        let loggedLines = sharedRecorder.recordedMessages.compactMap { $0.metadata["key"]?.description }.sorted()
        XCTAssertEqual(["1", "2", "3", "4", "5", "6", "7", "8"], loggedLines)
    }

    func testLogOutputToMessage() async throws {
        let sharedRecorder = LogRecorderHandler()
        var recordedLogger = Logger(label: "recorder", factory: { label in sharedRecorder })
        recordedLogger.logLevel = .info  // don't give us the normal messages
        recordedLogger[metadataKey: "yo"] = "hey"

        try await ProcessExecutor.runLogOutput(
            group: self.group,
            executable: "/bin/sh",
            ["-c", "echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8;"],
            standardInput: EOFSequence(),
            logger: recordedLogger,
            logConfiguration: OutputLoggingSettings(logLevel: .critical, to: .logMessage)
        ).throwIfNonZero()
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.level == .critical })
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["key"] == nil })
        XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["yo"] == "hey" })
        let loggedLines = sharedRecorder.recordedMessages.map { $0.message.description }.sorted()
        XCTAssertEqual(["1", "2", "3", "4", "5", "6", "7", "8"], loggedLines)
    }

    func testProcessOutputByLine() async throws {
        let collectedLines: NIOLockedValueBox<[(String, String)]> = NIOLockedValueBox([])
        try await ProcessExecutor.runProcessingOutput(
            group: self.group,
            executable: "/bin/sh",
            [
                "-c",
                """
                ( echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8; ) | \
                /bin/dd bs=1000 status=none
                """,
            ],
            standardInput: EOFSequence(),
            outputProcessor: { stream, line in
                collectedLines.withLockedValue { collection in
                    collection.append((stream.description, String(buffer: line)))
                }
            },
            splitOutputIntoLines: true,
            logger: self.logger
        ).throwIfNonZero()
        XCTAssertEqual(
            ["1", "2", "3", "4", "5", "6", "7", "8"],
            collectedLines.withLockedValue { $0.map { $0.1 } }.sorted()
        )
    }

    func testProcessOutputInChunks() async throws {
        let collectedBytes = ManagedAtomic<Int>(0)
        try await ProcessExecutor.runProcessingOutput(
            group: self.group,
            executable: "/bin/dd",
            ["if=/dev/zero", "bs=\(1024*1024)", "count=20", "status=none"],
            standardInput: EOFSequence(),
            outputProcessor: { stream, chunk in
                XCTAssertEqual(stream, .standardOutput)
                XCTAssert(chunk.withUnsafeReadableBytes { $0.allSatisfy({ $0 == 0 }) })
                collectedBytes.wrappingIncrement(by: chunk.readableBytes, ordering: .relaxed)
            },
            splitOutputIntoLines: true,
            logger: self.logger
        ).throwIfNonZero()
        XCTAssertEqual(20 * 1024 * 1024, collectedBytes.load(ordering: .relaxed))
    }

    func testBasicRunMethodWorks() async throws {
        try await ProcessExecutor.run(
            group: self.group,
            executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=100"],
            standardInput: EOFSequence(),
            logger: self.logger
        ).throwIfNonZero()
    }

    func testCollectJustStandardOutput() async throws {
        let allInfo = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=1"],
            standardInput: EOFSequence(),
            collectStandardOutput: true,
            collectStandardError: false,
            perStreamCollectionLimitBytes: 1024 * 1024,
            logger: self.logger
        )
        XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
        XCTAssertNil(allInfo.standardError)
        XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardOutput)
    }

    func testCollectJustStandardError() async throws {
        let allInfo = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/sh", ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1 status=none"],
            standardInput: EOFSequence(),
            collectStandardOutput: false,
            collectStandardError: true,
            perStreamCollectionLimitBytes: 1024 * 1024,
            logger: self.logger
        )
        XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
        XCTAssertNil(allInfo.standardOutput)
        XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardError)
    }

    func testCollectNothing() async throws {
        let allInfo = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/sh", ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=100 status=none"],
            standardInput: EOFSequence(),
            collectStandardOutput: false,
            collectStandardError: false,
            perStreamCollectionLimitBytes: 1024 * 1024,
            logger: self.logger
        )
        XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
        XCTAssertNil(allInfo.standardOutput)
        XCTAssertNil(allInfo.standardError)
    }

    func testCollectStdOutAndErr() async throws {
        let allInfo = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/sh",
            [
                "-c",
                """
                /bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1 status=none;
                /bin/dd if=/dev/zero bs=100 count=1 status=none;
                """,
            ],
            standardInput: EOFSequence(),
            collectStandardOutput: true,
            collectStandardError: true,
            perStreamCollectionLimitBytes: 1024 * 1024,
            logger: self.logger
        )
        XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
        XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardError)
        XCTAssertEqual(ByteBuffer(repeating: 0, count: 100), allInfo.standardOutput)
    }

    func testTooMuchToCollectStdout() async throws {
        do {
            let result = try await ProcessExecutor.runCollectingOutput(
                group: self.group,
                executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=1"],
                standardInput: EOFSequence(),
                collectStandardOutput: true,
                collectStandardError: false,
                perStreamCollectionLimitBytes: 1024 * 1024 - 1,
                logger: self.logger
            )
            XCTFail("should've thrown but got result: \(result)")
        } catch {
            XCTAssertTrue(error is ProcessExecutor.TooMuchProcessOutputError)
            XCTAssertEqual(
                ProcessOutputStream.standardOutput,
                (error as? ProcessExecutor.TooMuchProcessOutputError)?.stream
            )
        }
    }

    func testTooMuchToCollectStderr() async throws {
        do {
            let result = try await ProcessExecutor.runCollectingOutput(
                group: self.group,
                executable: "/bin/dd",
                ["if=/dev/zero", "bs=\(1024 * 1024)", "of=/dev/stderr", "count=1", "status=none"],
                standardInput: EOFSequence(),
                collectStandardOutput: false,
                collectStandardError: true,
                perStreamCollectionLimitBytes: 1024 * 1024 - 1,
                logger: self.logger
            )
            XCTFail("should've thrown but got result: \(result)")
        } catch {
            XCTAssertTrue(error is ProcessExecutor.TooMuchProcessOutputError)
            XCTAssertEqual(
                ProcessOutputStream.standardError,
                (error as? ProcessExecutor.TooMuchProcessOutputError)?.stream
            )
        }
    }

    func testCollectEmptyStringFromStdoutAndErr() async throws {
        let allInfo = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/sh",
            ["-c", ""],
            standardInput: EOFSequence(),
            collectStandardOutput: true,
            collectStandardError: true,
            perStreamCollectionLimitBytes: 1024 * 1024,
            logger: self.logger
        )
        XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
        XCTAssertEqual(ByteBuffer(), allInfo.standardError)
        XCTAssertEqual(ByteBuffer(), allInfo.standardOutput)
    }

    func testExecutableDoesNotExist() async throws {
        let exe = ProcessExecutor(
            group: self.group,
            executable: "/dev/null/does/not/exist",
            [],
            standardInput: EOFSequence(),
            standardOutput: .discard,
            standardError: .discard,
            logger: self.logger
        )
        do {
            let result = try await exe.run()
            XCTFail("got result for bad executable: \(result)")
        } catch {
            XCTAssertEqual(NSCocoaErrorDomain, (error as NSError).domain, "\(error)")
            XCTAssertEqual(NSFileNoSuchFileError, (error as NSError).code, "\(error)")
        }
    }

    func testAPIsWithoutELGOrLoggerArguments() async throws {
        let exe = ProcessExecutor(
            executable: "/bin/sh", ["-c", "true"],
            standardInput: EOFSequence(),
            standardOutput: .discard,
            standardError: .discard
        )
        try await exe.run().throwIfNonZero()

        try await ProcessExecutor.run(
            executable: "/bin/sh", ["-c", "true"],
            standardInput: EOFSequence()
        ).throwIfNonZero()

        try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/sh",
            ["-c", "true"],
            standardInput: EOFSequence(),
            collectStandardOutput: false,
            collectStandardError: false
        ).exitReason.throwIfNonZero()

        try await ProcessExecutor.runProcessingOutput(
            executable: "/bin/sh",
            ["-c", "true"],
            standardInput: EOFSequence()
        ) { _, _ in
            return
        }.throwIfNonZero()

        try await ProcessExecutor.runLogOutput(
            executable: "/bin/sh",
            ["-c", "true"],
            standardInput: EOFSequence(),
            logger: self.logger,
            logConfiguration: .init(logLevel: .critical, to: .logMessage)
        ).throwIfNonZero()
    }

    func testAPIsWithoutELGStandardInputOrLoggerArguments() async throws {
        let exe = ProcessExecutor(
            executable: "/bin/sh", ["-c", "true"],
            standardOutput: .discard,
            standardError: .discard
        )
        try await exe.run().throwIfNonZero()

        let exeStream = ProcessExecutor(executable: "/bin/sh", ["-c", "true"])
        #if compiler(>=5.8)
            async let stdout = Array(exeStream.standardOutput)
            async let stderr = Array(exeStream.standardError)
        #else
            async let stdout = {
                var chunks: [ByteBuffer] = []
                for try await chunk in await exeStream.standardOutput {
                    chunks.append(chunk)
                }
                return chunks
            }()
            async let stderr = {
                var chunks: [ByteBuffer] = []
                for try await chunk in await exeStream.standardError {
                    chunks.append(chunk)
                }
                return chunks
            }()
        #endif
        try await exeStream.run().throwIfNonZero()
        let out = try await stdout
        let err = try await stderr
        XCTAssertEqual([], out)
        XCTAssertEqual([], err)

        try await ProcessExecutor.run(executable: "/bin/sh", ["-c", "true"]).throwIfNonZero()

        try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/sh",
            ["-c", "true"],
            collectStandardOutput: false,
            collectStandardError: false
        ).exitReason.throwIfNonZero()

        try await ProcessExecutor.runProcessingOutput(executable: "/bin/sh", ["-c", "true"]) { _, _ in
            return
        }.throwIfNonZero()

        try await ProcessExecutor.runLogOutput(
            executable: "/bin/sh",
            ["-c", "true"],
            logger: self.logger,
            logConfiguration: .init(logLevel: .critical, to: .logMessage)
        ).throwIfNonZero()
    }

    func testStdoutAndStderrToSameFileWorks() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
        }

        for (stdoutMode, stderrMode) in [("shared", "shared"), ("shared", "owned"), ("owned", "shared")] {
            let filePath = tempDir.appendingPathComponent("file-\(stdoutMode)-\(stderrMode)")
            let fd = try FileDescriptor.open(
                .init(filePath.path.removingPercentEncoding!),
                .writeOnly,
                options: .create,
                permissions: [.ownerRead, .ownerWrite]
            )
            defer {
                if stdoutMode == "shared" && stderrMode == "shared" {
                    XCTAssertNoThrow(try fd.close())
                }
            }

            let stdout: ProcessOutput
            let stderr: ProcessOutput

            if stdoutMode == "owned" {
                stdout = .fileDescriptor(takingOwnershipOf: fd)
            } else {
                stdout = .fileDescriptor(sharing: fd)
            }
            if stderrMode == "owned" {
                stderr = .fileDescriptor(takingOwnershipOf: fd)
            } else {
                stderr = .fileDescriptor(sharing: fd)
            }

            let command =
                "for o in 1 2; do i=1000; while [ $i -gt 0 ]; do echo $o >&$o; i=$(( $i - 1 )); done & done; wait"
            let exe = ProcessExecutor(
                group: self.group,
                executable: "/bin/sh",
                ["-c", command],
                standardInput: EOFSequence(),
                standardOutput: stdout,
                standardError: stderr,
                logger: self.logger
            )
            try await exe.run().throwIfNonZero()
            let actualOutput = try Data(contentsOf: filePath)
            XCTAssertEqual(4000, actualOutput.count, "\(stdoutMode)-\(stderrMode)")

            var expectedOutput = Data()
            expectedOutput.append(Data(repeating: UInt8(ascii: "\n"), count: 2000))
            expectedOutput.append(Data(repeating: UInt8(ascii: "1"), count: 1000))
            expectedOutput.append(Data(repeating: UInt8(ascii: "2"), count: 1000))
            XCTAssertEqual(expectedOutput, Data(actualOutput.sorted()), "\(stdoutMode)-\(stderrMode)")
        }
    }

    func testCanReliablyKillProcessesEvenWithSigmask() async throws {
        let exitReason = try await withThrowingTaskGroup(
            of: ProcessExitReason?.self,
            returning: ProcessExitReason.self
        ) { group in
            group.addTask {
                return try await ProcessExecutor.run(
                    executable: "/bin/sh",
                    ["-c", "trap 'echo no' TERM; while true; do sleep 1; done"]
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000)
                return nil
            }

            while let result = try await group.next() {
                group.cancelAll()
                if let result = result {
                    return result
                }
            }
            preconditionFailure("this should be impossible, task should've returned a result")
        }
        XCTAssertEqual(.signal(SIGKILL), exitReason)
    }

    func testCancelProcessVeryEarlyOnStressTest() async throws {
        for i in 0..<100 {
            self.logger.debug("iteration go", metadata: ["iteration-number": "\(i)"])
            let exitReason = try await withThrowingTaskGroup(
                of: ProcessExitReason?.self,
                returning: ProcessExitReason.self
            ) { group in
                group.addTask { [logger = self.logger!] in
                    return try await ProcessExecutor.run(
                        executable: "/bin/sleep", ["100000"],
                        logger: logger
                    )
                }
                group.addTask { [logger = self.logger!] in
                    let waitNS = UInt64.random(in: 0..<10_000_000)
                    logger.info("waiting", metadata: ["wait-ns": "\(waitNS)"])
                    try? await Task.sleep(nanoseconds: waitNS)
                    return nil
                }

                while let result = try await group.next() {
                    group.cancelAll()
                    if let result = result {
                        return result
                    }
                }
                preconditionFailure("this should be impossible, task should've returned a result")
            }
            XCTAssertEqual(.signal(SIGKILL), exitReason, "iteration \(i)")
        }
    }

    func testShortestManuallyMergedOutput() async throws {
        let exe = ProcessExecutor(executable: "/bin/bash", ["-c", "echo hello world"])
        async let result = exe.run()
        let lines = try await Array(
            merge(exe.standardOutput.splitIntoLines(), exe.standardError.splitIntoLines()).strings
        )
        XCTAssertEqual(["hello world"], lines)
        try await result.throwIfNonZero()
    }

    func testShortestJustGiveMeTheOutput() async throws {
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/bash",
            ["-c", "echo hello world"],
            collectStandardOutput: true,
            collectStandardError: true
        )
        XCTAssertEqual("hello world\n", result.standardOutput.map { String(buffer: $0) })
        XCTAssertEqual("", result.standardError.map { String(buffer: $0) })
        XCTAssertEqual(.exit(0), result.exitReason)
    }

    func testKillProcess() async throws {
        let p = ProcessExecutor(
            executable: "/bin/bash",
            ["-c", "while true; do echo A; sleep 1; done"],
            standardError: .discard
        )
        async let result = p.run()
        var outputIterator = await p.standardOutput.makeAsyncIterator()
        let firstChunk = try await outputIterator.next()
        XCTAssertEqual(UInt8(ascii: "A"), firstChunk?.readableBytesView.first)
        try await p.sendSignal(SIGKILL)
        let finalResult = try await result
        XCTAssertEqual(.signal(SIGKILL), finalResult)
        while try await outputIterator.next() != nil {}
    }

    func testCanDealWithRunawayChildProcesses() async throws {
        self.logger = Logger(label: "x")
        self.logger.logLevel = .info
        let p = ProcessExecutor(
            executable: "/bin/bash",
            [
                "-c",
                """
                set -e
                /usr/bin/yes "Runaway process from \(#function), please file a swift-async-process bug." > /dev/null &
                child_pid=$!
                trap "echo >&2 'child: received signal, killing grand child ($child_pid)'; kill $child_pid" INT
                echo "$$" # communicate our pid to our parent
                echo "$child_pid" # communicate the child pid to our parent
                exec >&- # close stdout
                echo "child: waiting for grand child, pid: $child_pid" >&2
                wait
                """,
            ],
            standardError: .inherit,
            teardownSequence: [
                .sendSignal(SIGINT, allowedTimeToExitNS: 10_000_000_000)
            ],
            logger: self.logger
        )

        try await withThrowingTaskGroup(of: (pid_t, pid_t)?.self) { group in
            group.addTask {
                let result = try await p.run()
                XCTAssertEqual(.exit(128 + SIGINT), result)
                return nil
            }

            group.addTask {
                let pidStrings = String(buffer: try await p.standardOutput.pullAllOfIt()).split(separator: "\n")
                guard let childPID = pid_t((pidStrings.dropFirst(0).first ?? "n/a")) else {
                    XCTFail("couldn't get child's pid from \(pidStrings)")
                    return nil
                }
                guard let grandChildPID = pid_t((pidStrings.dropFirst(1).first ?? "n/a")) else {
                    XCTFail("couldn't get grand child's pid from \(pidStrings)")
                    return nil
                }
                return (childPID, grandChildPID)
            }

            let maybePids = try await group.next()!
            let (childPID, grandChildPID) = try XCTUnwrap(maybePids)
            group.cancelAll()
            try await group.waitForAll()

            // Let's check that the subprocess (/usr/bin/yes) of our subprocess (/bin/bash) is actually dead
            // This is a tiny bit racy because the pid isn't immediately invalidated, so let's allow a few failures
            for attempt in 1 ..< .max {
                let killRet = kill(grandChildPID, 0)
                let errnoCode = errno
                if killRet == 0 && attempt < 10 {
                    logger.error("we expected kill to fail but it didn't. Attempt \(attempt), trying again...")
                    if attempt > 7 {
                        fputs("## lsof child:\n", stderr)
                        fputs(((try? await runLSOF(pid: childPID)) ?? "n/a") + "\n", stderr)
                        fputs("## lsof grand child:\n", stderr)
                        fputs(((try? await runLSOF(pid: grandChildPID)) ?? "n/a") + "\n", stderr)
                        fflush(stderr)
                    }
                    usleep(useconds_t(attempt) * 100_000)
                    continue
                }
                XCTAssertEqual(-1, killRet, "\(blockingLSOF(pid: grandChildPID))")
                XCTAssertEqual(ESRCH, errnoCode)
                break
            }
        }
    }

    func testShutdownSequenceWorks() async throws {
        let p = ProcessExecutor(
            executable: "/bin/bash",
            [
                "-c",
                """
                set -e
                trap 'echo saw SIGQUIT; echo >&2 saw SIGQUIT' QUIT
                trap 'echo saw SIGTERM; echo >&2 saw SIGTERM' TERM
                trap 'echo saw SIGINT; echo >&2 saw SIGINT; exit 3;' INT
                echo OK
                while true; do sleep 0.1; done
                exit 2
                """,
            ],
            standardError: .discard,
            teardownSequence: [
                .sendSignal(SIGQUIT, allowedTimeToExitNS: 200_000_000),
                .sendSignal(SIGTERM, allowedTimeToExitNS: 200_000_000),
                .sendSignal(SIGINT, allowedTimeToExitNS: 1_000_000_000),
            ],
            logger: self.logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let result = try await p.run()
                XCTAssertEqual(.exit(3), result)
            }
            var allLines: [String] = []
            for try await line in await p.standardOutput.splitIntoLines().strings {
                if line == "OK" {
                    group.cancelAll()
                }
                allLines.append(line)
            }
            try await group.waitForAll()
            XCTAssertEqual(["OK", "saw SIGQUIT", "saw SIGTERM", "saw SIGINT"], allLines)
        }
    }

    func testCanInheritRandomFileDescriptors() async throws {
        guard ProcessExecutor.isBackedByPSProcess else {
            return  // Foundation.Process does not support this
        }
        var spawnOptions = ProcessExecutor.SpawnOptions.default
        spawnOptions.closeOtherFileDescriptors = false
        var pipeFDs: [Int32] = [-1, -1]
        pipeFDs.withUnsafeMutableBufferPointer { ptr in
            XCTAssertEqual(0, pipe(ptr.baseAddress!), "pipe failed: \(errno))")
        }
        defer {
            for fd in pipeFDs where fd >= 0 {
                close(fd)
            }
        }

        let pipeWriteFD = pipeFDs[1]
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/bash",
            ["-c", "echo hello from child >&\(pipeWriteFD); echo wrote into \(pipeWriteFD), echo exit code $?"],
            spawnOptions: spawnOptions,
            collectStandardOutput: true,
            collectStandardError: true
        )
        close(pipeFDs[1])
        pipeFDs[1] = -1
        var readBytes: [UInt8] = Array(repeating: 0, count: 1024)
        let readBytesCount = try readBytes.withUnsafeMutableBytes { readBytesPtr in
            try FileDescriptor(rawValue: pipeFDs[0]).read(into: readBytesPtr, retryOnInterrupt: true)
        }
        XCTAssertEqual(17, readBytesCount)
        XCTAssertEqual(.exit(0), result.exitReason)
        XCTAssertEqual("wrote into \(pipeWriteFD), echo exit code 0\n", String(buffer: result.standardOutput!))
        XCTAssertEqual("", String(buffer: result.standardError!))
        XCTAssertEqual(
            "hello from child\n",
            String(decoding: readBytes.prefix { $0 != 0 }, as: UTF8.self)
        )
    }

    func testDoesNotInheritRandomFileDescriptorsByDefault() async throws {
        let spawnOptions = ProcessExecutor.SpawnOptions.default
        var pipeFDs: [Int32] = [-1, -1]
        pipeFDs.withUnsafeMutableBufferPointer { ptr in
            XCTAssertEqual(0, pipe(ptr.baseAddress!), "pipe failed: \(errno))")
        }
        defer {
            for fd in pipeFDs where fd >= 0 {
                close(fd)
            }
        }

        let pipeWriteFD = pipeFDs[1]
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/bash",
            ["-c", "echo hello from child >&\(pipeWriteFD); echo wrote into \(pipeWriteFD), echo exit code $?"],
            spawnOptions: spawnOptions,
            collectStandardOutput: true,
            collectStandardError: true
        )
        close(pipeFDs[1])
        pipeFDs[1] = -1
        var readBytes: [UInt8] = Array(repeating: 0, count: 1024)
        let readBytesCount = try readBytes.withUnsafeMutableBytes { readBytesPtr in
            try FileDescriptor(rawValue: pipeFDs[0]).read(into: readBytesPtr, retryOnInterrupt: true)
        }
        XCTAssertEqual(0, readBytesCount)
        XCTAssertEqual(.exit(0), result.exitReason)
        XCTAssertEqual("wrote into \(pipeWriteFD), echo exit code 1\n", String(buffer: result.standardOutput!))
        XCTAssertNotEqual("", String(buffer: result.standardError!))
        XCTAssertEqual("", String(decoding: readBytes.prefix { $0 != 0 }, as: UTF8.self))
    }

    func testCanChangeCWD() async throws {
        var spawnOptions = ProcessExecutor.SpawnOptions.default
        spawnOptions.changedWorkingDirectory = "/"
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/bash",
            ["-c", "echo $PWD"],
            spawnOptions: spawnOptions,
            collectStandardOutput: true,
            collectStandardError: true
        )
        XCTAssertEqual(.exit(0), result.exitReason)
        XCTAssertEqual("/\n", String(buffer: result.standardOutput!))
        XCTAssertEqual("", String(buffer: result.standardError!))
    }

    func testCanChangeCWDToNonExistent() async throws {
        var spawnOptions = ProcessExecutor.SpawnOptions.default
        spawnOptions.changedWorkingDirectory = "/dev/null/does/not/exist"
        do {
            let result = try await ProcessExecutor.runCollectingOutput(
                executable: "/bin/bash",
                ["-c", "pwd"],
                spawnOptions: spawnOptions,
                collectStandardOutput: true,
                collectStandardError: true
            )
            XCTFail("succeeded but shouldn't have: \(result)")
        } catch {
            XCTAssertEqual(NSCocoaErrorDomain, (error as NSError).domain, "\(error)")
            XCTAssertEqual(NSFileNoSuchFileError, (error as NSError).code, "\(error)")
        }
    }

    func testCanReadThePid() async throws {
        let (inputConsumer, inputProducer) = AsyncStream.justMakeIt(elementType: ByteBuffer.self)
        let p = ProcessExecutor(
            executable: "/bin/bash",
            ["-c", #"read -r line && echo "$line" && echo ok $$"#],
            standardInput: inputConsumer,
            standardOutput: .stream,
            standardError: .stream,
            logger: self.logger
        )
        async let resultAsync = p.run()
        async let stdoutAsync = Array(p.standardOutput)
        async let stderrAsync = Array(p.standardError)
        var pid: pid_t? = nil

        // Wait until pid goes `nil` -> actual pid
        while pid == nil {
            pid = p.bestEffortProcessIdentifier
            if pid != nil { continue }
            self.logger.info("no pid yet, waiting", metadata: ["process": "\(p)"])
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        inputProducer.yield(ByteBuffer(string: "hello world\n"))
        inputProducer.finish()
        let result = try await resultAsync
        let stdout = try await stdoutAsync
        let stderr = try await stderrAsync
        XCTAssertEqual(.exit(0), result)
        XCTAssertEqual(
            "hello world\nok \(pid ?? -1)\n",
            String(buffer: stdout.reduce(into: ByteBuffer(), { acc, next in acc.writeImmutableBuffer(next) }))
        )
        XCTAssertEqual(
            "",
            String(buffer: stderr.reduce(into: ByteBuffer(), { acc, next in acc.writeImmutableBuffer(next) }))
        )

        // Wait until pid goes actual pid -> `nil`
        while pid != nil {
            pid = p.bestEffortProcessIdentifier
            if pid == nil { continue }
            self.logger.info("pid still set, waiting", metadata: ["process": "\(p)"])
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testVeryHighFDs() async throws {
        var openedFDs: [CInt] = []

        // Open /dev/null to use as source for duplication
        let devNullFD = open("/dev/null", O_RDONLY)
        guard devNullFD != -1 else {
            XCTFail("Failed to open /dev/null")
            return
        }
        defer {
            let closeResult = close(devNullFD)
            XCTAssertEqual(0, closeResult, "Failed to close /dev/null FD")
        }

        for candidate in sequence(first: CInt(1), next: { $0 <= CInt.max / 2 ? $0 * 2 : nil }) {
            // Use fcntl with F_DUPFD to find next available FD >= candidate
            let fd = fcntl(devNullFD, F_DUPFD, candidate)
            if fd == -1 {
                // Failed to allocate FD >= candidate, try next power of 2
                self.logger.debug(
                    "already unavailable, skipping",
                    metadata: ["candidate": "\(candidate)", "errno": "\(errno)"]
                )
                continue
            } else {
                openedFDs.append(fd)
                self.logger.debug("Opened FD in parent", metadata: ["fd": "\(fd)"])
            }
        }

        defer {
            for fd in openedFDs {
                let closeResult = close(fd)
                XCTAssertEqual(0, closeResult, "Failed to close FD \(fd)")
            }
        }

        // Create shell script that checks each FD passed as arguments
        let shellScript = """
            for fd in "$@"; do
                if [ -e "/proc/self/fd/$fd" ] || [ -e "/dev/fd/$fd" ]; then
                    echo "- fd: $fd: OPEN"
                else
                    echo "- fd: $fd: CLOSED"
                fi
            done
            """

        var arguments = ["-c", shellScript, "--"]
        arguments.append(contentsOf: openedFDs.map { "\($0)" })

        let result = try await ProcessExecutor.runCollectingOutput(
            group: self.group,
            executable: "/bin/sh",
            arguments,
            standardInput: EOFSequence(),
            collectStandardOutput: true,
            collectStandardError: true,
            logger: self.logger
        )
        try result.exitReason.throwIfNonZero()

        // Assert stderr is empty
        XCTAssertEqual("", String(buffer: result.standardError!))

        // Assert stdout contains exactly the expected output (all FDs closed)
        let expectedOutput = openedFDs.map { "- fd: \($0): CLOSED" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(expectedOutput, String(buffer: result.standardOutput!))
    }

    func testStandardInputIgnoredMeansImmediateEOF() async throws {
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/sh",
            [
                "-c",
                #"""
                set -eu
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 0
                """#,
            ],
            collectStandardOutput: true,
            collectStandardError: true
        )
        try result.exitReason.throwIfNonZero()
        XCTAssertEqual("", String(buffer: result.standardOutput!))
        XCTAssertEqual("", String(buffer: result.standardError!))
    }

    func testStandardInputStreamWriteErrorsBlowUpOldSchoolRunSpawnOnProcessExit() async throws {
        do {
            let result = try await ProcessExecutor(
                executable: "/bin/sh",
                [
                    "-c",
                    #"""
                    set -e
                    read -r line
                    if [ "$line" = "go" ]; then
                        echo "GO"
                        exit 0 # We're just exiting here which will have the effect of stdin closing
                    fi
                    echo "PROBLEM"
                    while read -r line; do
                        echo "unexpected input $line"
                    done
                    exit 1
                    """#,
                ],
                standardInput: sequence(
                    first: ByteBuffer(string: "go\n"),
                    next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
                ).async,
                standardOutput: .discard,
                standardError: .discard
            ).run()
            XCTFail("unexpected result: \(result)")
        } catch let error as NIO.IOError {
            XCTAssert(
                [
                    EPIPE,
                    EBADF,  // don't worry, this is a NIO-synthesised (already closed) EBADF
                ].contains(error.errnoCode),
                "unexpected error: \(error)"
            )
        }
    }

    func testStandardInputStreamWriteErrorsBlowUpOldSchoolRunOnStandardInputClose() async throws {
        do {
            let result = try await ProcessExecutor(
                executable: "/bin/sh",
                [
                    "-c",
                    #"""
                    set -e
                    read -r line
                    if [ "$line" = "go" ]; then
                        echo "GO"
                        exec <&- # close stdin but stay alive
                        while true; do sleep 1; done
                        exit 0
                    fi
                    echo "PROBLEM"
                    while read -r line; do
                        echo "unexpected input $line"
                    done
                    exit 1
                    """#,
                ],
                standardInput: sequence(
                    first: ByteBuffer(string: "go\n"),
                    next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
                ).async,
                standardOutput: .discard,
                standardError: .discard
            ).run()
            XCTFail("unexpected result: \(result)")
        } catch let error as NIO.IOError {
            XCTAssert(
                [
                    EPIPE,
                    EBADF,  // don't worry, this is a NIO-synthesised (already closed) EBADF
                ].contains(error.errnoCode),
                "unexpected error: \(error)"
            )
        }
    }

    func testStandardInputStreamWriteErrorsDoNotBlowUpRunCollectingInputOnProcessExit() async throws {
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/sh",
            [
                "-c",
                #"""
                set -e
                read -r line
                if [ "$line" = "go" ]; then
                    echo "GO"
                    exit 0 # We're just exiting here which will have the effect of stdin closing
                fi
                echo "PROBLEM"
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 1
                """#,
            ],
            standardInput: sequence(
                first: ByteBuffer(string: "go\n"),
                next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
            ).async,
            collectStandardOutput: true,
            collectStandardError: true
        )
        XCTAssertEqual(.exit(0), result.exitReason)  // child exits by itself
        XCTAssertNotNil(result.standardInputWriteError)
        XCTAssertEqual(
            EPIPE,
            (result.standardInputWriteError as? NIO.IOError).map { ioError in
                if ioError.errnoCode == EBADF {
                    // Don't worry, not a real EBADF, just a NIO synthesised one
                    // https://github.com/apple/swift-nio/issues/3292
                    // Let's fudge the error into a sensible one.
                    let ioError = NIO.IOError(errnoCode: EPIPE, reason: ioError.description)
                    return ioError
                } else {
                    return ioError
                }
            }?.errnoCode,
            "\(result.standardInputWriteError.debugDescription)"
        )
        XCTAssertEqual("GO\n", String(buffer: result.standardOutput!))
        XCTAssertEqual("", String(buffer: result.standardError!))
    }

    func testStandardInputStreamWriteErrorsDoNotBlowUpRunCollectingInputOnStandardInputClose() async throws {
        let result = try await ProcessExecutor.runCollectingOutput(
            executable: "/bin/sh",
            [
                "-c",
                #"""
                set -e
                read -r line
                if [ "$line" = "go" ]; then
                    echo "GO"
                    exec <&- # close stdin but stay alive
                    while true; do sleep 1; done
                    exit 0
                fi
                echo "PROBLEM"
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 1
                """#,
            ],
            standardInput: sequence(
                first: ByteBuffer(string: "go\n"),
                next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
            ).async,
            collectStandardOutput: true,
            collectStandardError: true
        )
        XCTAssertEqual(.signal(9), result.exitReason)  // Child doesn't die by itself, so it'll be killed by our cancel
        XCTAssertNotNil(result.standardInputWriteError)
        XCTAssertEqual(
            EPIPE,
            (result.standardInputWriteError as? NIO.IOError).map { ioError in
                if ioError.errnoCode == EBADF {
                    // Don't worry, not a real EBADF, just a NIO synthesised one
                    // https://github.com/apple/swift-nio/issues/3292
                    // Let's fudge the error into a sensible one.
                    let ioError = NIO.IOError(errnoCode: EPIPE, reason: ioError.description)
                    return ioError
                } else {
                    return ioError
                }
            }?.errnoCode,
            "\(result.standardInputWriteError.debugDescription)"
        )
        XCTAssertEqual("GO\n", String(buffer: result.standardOutput!))
        XCTAssertEqual("", String(buffer: result.standardError!))
    }

    func testStandardInputStreamWriteErrorsCanBeIgnored() async throws {
        var spawnOptions = ProcessExecutor.SpawnOptions.default
        spawnOptions.ignoreStdinStreamWriteErrors = true
        do {
            let result = try await ProcessExecutor.runCollectingOutput(
                executable: "/bin/sh",
                [
                    "-c",
                    #"""
                    set -e
                    read -r line
                    if [ "$line" = "go" ]; then
                        echo "GO"
                        exit 0 # We're just exiting here which will have the effect of stdin closing
                    fi
                    echo "PROBLEM"
                    while read -r line; do
                        echo "unexpected input $line"
                    done
                    exit 1
                    """#,
                ],
                spawnOptions: spawnOptions,
                standardInput: sequence(
                    first: ByteBuffer(string: "go\n"),
                    next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
                ).async,
                collectStandardOutput: true,
                collectStandardError: true
            )
            try result.exitReason.throwIfNonZero()
            XCTAssertEqual("GO\n", String(buffer: result.standardOutput!))
            XCTAssertEqual("", String(buffer: result.standardError!))
        }
    }

    func testStandardInputStreamWriteErrorsCanBeReceivedThroughExtendedResults() async throws {
        // The default is
        //    spawnOptions.cancelProcessOnStandardInputWriteFailure = true
        // therefore, this should not hang and the program should get killed with SIGKILL (due to cancellation).
        let exe = ProcessExecutor(
            executable: "/bin/sh",
            [
                "-c",
                #"""
                set -eu
                read -r line
                if [ "$line" = "go" ]; then
                    echo "GO"
                    exec <&- # close stdin but stay alive
                    while true; do sleep 1; done
                    exit 0
                fi
                echo "PROBLEM"
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 1
                """#,
            ],
            standardInput: sequence(
                first: ByteBuffer(string: "go\n"),
                next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
            ).async
        )
        async let resultAsync = exe.runWithExtendedInfo()
        for try await line in await merge(exe.standardOutput.splitIntoLines(), exe.standardError.splitIntoLines()) {
            if String(buffer: line) != "GO" {
                XCTFail("unexpected line: \(line)")
            }
        }
        let result = try await resultAsync
        XCTAssertEqual(.signal(SIGKILL), result.exitReason)
        XCTAssertThrowsError(try result.standardInputWriteError.map { throw $0 }) { error in
            if let error = error as? NIO.IOError {
                XCTAssert(
                    [
                        EPIPE,
                        EBADF,  // don't worry, this is a NIO-synthesised (already closed) EBADF
                    ].contains(error.errnoCode),
                    "unexpected error: \(error)"
                )
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCanMakeProgramHangWhenStdinIsClosedBecauseWeDisabledCancellation() async throws {
        // This is quite a complex test. Here we're closing stdin in the child process but disable automatic
        // parent process cancellation on child stdin write errors. Therefore, the child will hang until we cancel it
        // ourselves.
        var spawnOptions = ProcessExecutor.SpawnOptions.default
        spawnOptions.cancelProcessOnStandardInputWriteFailure = false
        let exe = ProcessExecutor(
            executable: "/bin/sh",
            [
                "-c",
                #"""
                set -eu
                read -r line
                if [ "$line" = "go" ]; then
                    echo "GO"
                    exec <&- # close stdin but stay alive
                    exec >&- # also close stdout to signal to parent
                    while true; do sleep 1; done
                    exit 0
                fi
                echo "PROBLEM"
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 1
                """#,
            ],
            spawnOptions: spawnOptions,
            standardInput: sequence(
                first: ByteBuffer(string: "go\n"),
                next: { _ in ByteBuffer(string: "extra line\n") }  // infinite sequence
            ).async
        )

        enum WhoReturned {
            case process(Result<ProcessExitExtendedInfo, any Error>)
            case stderr(Error?)
            case stdout(Error?)
            case sleep
        }
        await withTaskGroup(of: WhoReturned.self) { group in
            group.addTask {
                do {
                    let result = try await exe.runWithExtendedInfo()
                    return WhoReturned.process(.success(result))
                } catch {
                    return WhoReturned.process(.failure(error))
                }
            }
            group.addTask {
                do {
                    for try await line in await exe.standardError.splitIntoLines() {
                        XCTFail("unexpected stderr line: \(line)")
                    }
                    return .stderr(nil)
                } catch {
                    return .stderr(error)
                }
            }
            group.addTask {
                do {
                    for try await line in await exe.standardOutput.splitIntoLines() {
                        if line != ByteBuffer(string: "GO") {
                            XCTFail("unexpected stdout line: \(line)")
                        }
                    }
                    return .stdout(nil)
                } catch {
                    return .stdout(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return .sleep
            }

            let actualReturn1 = await group.next()!  // .stdout (likely) or .sleep (unlikely)
            let actualReturn2 = await group.next()!  // .sleep (likely) or .stdout (unlikely)
            group.cancelAll()
            let actualReturn3 = await group.next()!  // .stderr or .process
            let actualReturn4 = await group.next()!  // .stderr or .process

            switch actualReturn1 {
            case .stdout(let maybeError):
                XCTAssertNil(maybeError)
            case .sleep:
                ()
            default:
                XCTFail("unexpected: \(actualReturn1)")
            }
            switch actualReturn2 {
            case .stdout(let maybeError):
                XCTAssertNil(maybeError)
            case .sleep:
                ()
            default:
                XCTFail("unexpected: \(actualReturn2)")
            }
            switch actualReturn3 {
            case .stderr(let maybeError):
                XCTAssertNil(maybeError)
            case .process(let result):
                let exitReason = try? result.get()
                XCTAssertEqual(.signal(SIGKILL), exitReason?.exitReason)
                XCTAssertNotNil(exitReason?.standardInputWriteError)
            default:
                XCTFail("unexpected: \(actualReturn3)")
            }
            switch actualReturn4 {
            case .stderr(let maybeError):
                XCTAssertNil(maybeError)
            case .process(let result):
                let exitReason = try? result.get()
                XCTAssertEqual(.signal(SIGKILL), exitReason?.exitReason)
                XCTAssertNotNil(exitReason?.standardInputWriteError)
            default:
                XCTFail("unexpected: \(actualReturn4)")
            }
        }
    }

    func testWeDoNotHangIfStandardInputRemainsOpenButProcessExits() async throws {
        // This tests an odd situation: The child exits but stdin is still not closed, mostly happens if we inherit a
        // pipe that we still have another writer to.

        var sleepPidToKill: CInt?
        defer {
            if let sleepPidToKill {
                self.logger.debug(
                    "killing our sleep grand-child",
                    metadata: ["pid": "\(sleepPidToKill)"]
                )
                kill(sleepPidToKill, SIGKILL)
            } else {
                XCTFail("didn't find the pid of sleep to kill")
            }
        }
        do {  // We create a scope here to make sure we can leave the scope without hanging
            let (stdinStream, stdinStreamProducer) = AsyncStream.makeStream(of: ByteBuffer.self)
            let exe = ProcessExecutor(
                executable: "/bin/sh",
                [
                    "-c",
                    #"""
                    # This construction attempts to emulate a simple `sleep 12345678 < /dev/null` but some shells (eg. dash)
                    # won't allow stdin inheritance for background processes...
                    exec 2>&- # close stderr
                    exec 2<&0 # duplicate stdin into fd 2 (so we can inherit it into sleep

                    (
                        exec 0<&2  # map the duplicated fd 2 as our stdin
                        exec 2>&-  # close the duplicated fd2
                        exec sleep 12345678 # sleep (this will now have the origin stdin as its stdin)
                    ) & # uber long sleep that will inherit our stdin pipe
                    exec 2>&- # close duplicated 2

                    read -r line
                    echo "$line" # write back the line
                    echo "$!" # write back the sleep
                    exec >&-
                    exit 0
                    """#,
                ],
                standardInput: stdinStream
            )
            stdinStreamProducer.yield(ByteBuffer(string: "GO\n"))
            stdinStreamProducer.yield(ByteBuffer(repeating: 0x42, count: 16 * 1024 * 1024))
            async let resultAsync = exe.runWithExtendedInfo()
            async let stderrAsync = Array(exe.standardError)
            var stdoutLines = await exe.standardOutput.splitIntoLines().makeAsyncIterator()
            let lineGo = try await stdoutLines.next()
            XCTAssertEqual(ByteBuffer(string: "GO"), lineGo)
            let linePid = try await stdoutLines.next().map(String.init(buffer:))
            let sleepPid = try XCTUnwrap(linePid.flatMap { CInt($0) })
            self.logger.debug("found our sleep grand-child", metadata: ["pid": "\(sleepPid)"])
            sleepPidToKill = sleepPid
            let stderrBytes = try await stderrAsync
            XCTAssertEqual([], stderrBytes)
            let result = try await resultAsync
            XCTAssertEqual(.exit(0), result.exitReason)
            XCTAssertNotNil(result.standardInputWriteError)
            XCTAssertEqual(ChannelError.ioOnClosedChannel, result.standardInputWriteError as? ChannelError)
            stdinStreamProducer.finish()
        }
    }

    #if !os(Linux)  // https://github.com/apple/swift-nio/issues/3294
        func testWeDoHangIfStandardInputWriterCouldStillWriteIfWeDisableCancellingInputWriterAfterExit() async throws {
            // Here, we do the same thing as in testWeDoNotHangIfStandardInputRemainsOpenButProcessExits but to make matters
            // worse, we're setting `spawnOptions.cancelStandardInputWritingWhenProcessExits = false` which means that we're
            // not gonna return because the write will be hanging until we kill our long sleep.

            enum WhoReturned {
                case processRun
                case waiter
            }

            try await withThrowingTaskGroup(of: WhoReturned.self) { group in
                let (stdinStream, stdinStreamProducer) = AsyncStream.makeStream(of: ByteBuffer.self)
                var spawnOptions = ProcessExecutor.SpawnOptions.default
                spawnOptions.cancelStandardInputWritingWhenProcessExits = false
                let exe = ProcessExecutor(
                    executable: "/bin/sh",
                    [
                        "-c",
                        #"""
                        # This construction attempts to emulate a simple `sleep 12345678 < /dev/null` but some shells (eg. dash)
                        # won't allow stdin inheritance for background processes...
                        exec 2>&- # close stderr
                        exec 2<&0 # duplicate stdin into fd 2 (so we can inherit it into sleep

                        (
                            exec 0<&2  # map the duplicated fd 2 as our stdin
                            exec 2>&-  # close the duplicated fd2
                            exec sleep 12345678 # sleep (this will now have the origin stdin as its stdin)
                        ) & # uber long sleep that will inherit our stdin pipe
                        exec 2>&- # close duplicated 2

                        read -r line
                        echo "$line" # write back the line
                        echo "$!" # write back the sleep
                        exec >&-
                        exit 0
                        """#,
                    ],
                    spawnOptions: spawnOptions,
                    standardInput: stdinStream
                )
                stdinStreamProducer.yield(ByteBuffer(string: "GO\n"))
                stdinStreamProducer.yield(ByteBuffer(repeating: 0x42, count: 32 * 1024 * 1024))

                group.addTask {
                    let result = try await exe.runWithExtendedInfo()
                    XCTAssertEqual(.exit(0), result.exitReason)
                    XCTAssertNotNil(result.standardInputWriteError)
                    XCTAssert(
                        [
                            .some(EPIPE),
                            .some(EBADF),  // don't worry, this is a NIO-synthesised (already closed) EBADF
                        ].contains(result.standardInputWriteError.flatMap { $0 as? NIO.IOError }.map { $0.errnoCode }),
                        "unexpected error: \(result.standardInputWriteError.debugDescription)"
                    )
                    stdinStreamProducer.finish()
                    return .processRun
                }
                var stdoutLines = await exe.standardOutput.splitIntoLines().makeAsyncIterator()
                let lineGo = try await stdoutLines.next()
                XCTAssertEqual(ByteBuffer(string: "GO"), lineGo)
                let linePid = try await stdoutLines.next().map(String.init(buffer:))
                let sleepPid = try XCTUnwrap(linePid.flatMap { CInt($0) })
                self.logger.debug("found our sleep grand-child", metadata: ["pid": "\(sleepPid)"])

                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // Wait until we're confident that we're stuck
                    return .waiter
                }

                // The situation we set up is the following
                // - Our direct child process will have exited here
                // - Our grand child (sleep 12345678) is still running and has the stdin pipe
                // - We switched off cancelling the stdin writer when our child exits
                // - We're stuck now ...
                // - ... until our `.waiter` returns
                // - When we kill the grand-child
                // - Which then unblocks everything else

                let actualReturn1 = try await group.next()!
                XCTAssertEqual(.waiter, actualReturn1)

                let stderrBytes = try await Array(exe.standardError)
                XCTAssertEqual([], stderrBytes, "\(stderrBytes.map { $0.hexDump(format: .plain(maxBytes: .max)) })")

                let killRet = kill(sleepPid, SIGKILL)
                XCTAssertEqual(0, killRet, "kill failed: \(errno)")

                stdinStreamProducer.yield(ByteBuffer(repeating: 0x42, count: 1 * 1024 * 1024))

                let actualReturn2 = try await group.next()!
                XCTAssertEqual(.processRun, actualReturn2)
            }
        }
    #endif

    func testTinyOutputConsumedAfterRun() async throws {
        let exe = ProcessExecutor(
            executable: "/bin/sh",
            ["-c", "echo O; echo >&2 E"]
        )
        let result = try await exe.run()
        XCTAssertEqual(.exit(0), result)
        let stdout = try await Array(await exe.standardOutput.splitIntoLines())
        XCTAssertEqual([ByteBuffer(string: "O")], stdout)
        let stderr = try await Array(await exe.standardError.splitIntoLines())
        XCTAssertEqual([ByteBuffer(string: "E")], stderr)
    }

    func testTinyOutputConsumedDuringRun() async throws {
        let exe = ProcessExecutor(
            executable: "/bin/sh",
            ["-c", "echo O; echo >&2 E"]
        )
        async let asyncResult = exe.run()
        try await Task.sleep(nanoseconds: .random(in: 0..<10_000_000))
        let stdout = try await Array(await exe.standardOutput.splitIntoLines())
        XCTAssertEqual([ByteBuffer(string: "O")], stdout)
        let stderr = try await Array(await exe.standardError.splitIntoLines())
        XCTAssertEqual([ByteBuffer(string: "E")], stderr)
        let result = try await asyncResult
        XCTAssertEqual(.exit(0), result)
    }

    // MARK: - Setup/teardown
    override func setUp() async throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        self.logger = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

        // Make sure the singleton threads have booted (because they use file descriptors)
        try await MultiThreadedEventLoopGroup.singleton.next().submit {}.get()
        self.highestFD = highestOpenFD()
    }

    override func tearDown() {
        var highestFD: CInt? = nil
        for attempt in 0..<10 where highestFD != self.highestFD {
            if highestFD != nil {
                self.logger.debug(
                    "fd number differs",
                    metadata: [
                        "before-test": "\(self.highestFD.debugDescription)",
                        "after-test": "\(highestFD.debugDescription)",
                        "attempt": "\(attempt)",
                    ]
                )
                usleep(100_000)
            }
            highestFD = highestOpenFD()
        }
        XCTAssertEqual(self.highestFD, highestFD, "\(blockingLSOF(pid: getpid()))")
        self.highestFD = nil
        self.logger = nil

        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        self.group = nil
    }
}

extension AsyncStream {
    static func justMakeIt(elementType: Element.Type = Element.self) -> (
        consumer: AsyncStream<Element>, producer: AsyncStream<Element>.Continuation
    ) {
        var _producer: AsyncStream<Element>.Continuation?
        let stream = AsyncStream { producer in
            _producer = producer
        }

        return (stream, _producer!)
    }
}

extension AsyncSequence where Element == ByteBuffer {
    func pullAllOfIt() async throws -> ByteBuffer {
        var buffer: ByteBuffer? = nil
        for try await chunk in self {
            buffer.setOrWriteImmutableBuffer(chunk)
        }
        return buffer ?? ByteBuffer()
    }
}

extension ProcessExecutor {
    struct AllOfAProcess: Sendable {
        var exitReason: ProcessExitReason
        var standardOutput: ByteBuffer
        var standardError: ByteBuffer
    }

    private enum What {
        case exit(ProcessExitReason)
        case stdout(ByteBuffer)
        case stderr(ByteBuffer)
    }

    func runGetAllOutput() async throws -> AllOfAProcess {
        try await withThrowingTaskGroup(of: What.self, returning: AllOfAProcess.self) { group in
            group.addTask {
                return .exit(try await self.run())
            }
            group.addTask {
                return .stdout(try await self.standardOutput.pullAllOfIt())
            }
            group.addTask {
                return .stderr(try await self.standardError.pullAllOfIt())
            }

            var exitReason: ProcessExitReason?
            var stdout: ByteBuffer?
            var stderr: ByteBuffer?

            while let next = try await group.next() {
                switch next {
                case .exit(let value):
                    exitReason = value
                case .stderr(let value):
                    stderr = value
                case .stdout(let value):
                    stdout = value
                }
            }

            return AllOfAProcess(exitReason: exitReason!, standardOutput: stdout!, standardError: stderr!)
        }
    }
}

private func highestOpenFD() -> CInt? {
    #if os(macOS)
        guard let dirPtr = opendir("/dev/fd") else {
            return nil
        }
    #elseif os(Linux)
        guard let dirPtr = opendir("/proc/self/fd") else {
            return nil
        }
    #else
        return nil
    #endif
    defer {
        closedir(dirPtr)
    }
    var highestFDSoFar = CInt(0)

    while let dirEntPtr = readdir(dirPtr) {
        var entryName = dirEntPtr.pointee.d_name
        let thisFD = withUnsafeBytes(of: &entryName) { entryNamePtr -> CInt? in

            CInt(String(decoding: entryNamePtr.prefix(while: { $0 != 0 }), as: Unicode.UTF8.self))
        }
        highestFDSoFar = max(thisFD ?? -1, highestFDSoFar)
    }

    return highestFDSoFar
}

private func runLSOF(pid: pid_t) async throws -> String {
    #if canImport(Darwin)
        let lsofPath = "/usr/sbin/lsof"
    #else
        let lsofPath = "/usr/bin/lsof"
    #endif
    let result = try await ProcessExecutor.runCollectingOutput(
        executable: lsofPath,
        ["-Pnp", "\(pid)"],
        collectStandardOutput: true,
        collectStandardError: true
    )
    let outString = """
        exit code: \(result.exitReason)\n
        ## stdout
        \(String(buffer: result.standardOutput!))

        ## stderr
        \(String(buffer: result.standardError!))

        """
    return outString
}

private func blockingLSOF(pid: pid_t) -> String {
    let box = NIOLockedValueBox<String>("n/a")
    let sem = DispatchSemaphore(value: 0)
    Task {
        defer {
            sem.signal()
        }
        do {
            let outString = try await runLSOF(pid: pid)
            box.withLockedValue { $0 = outString }
        } catch {
            box.withLockedValue { debugString in
                debugString = "ERROR: \(error)"
            }
        }
    }
    _ = sem.wait(timeout: .now() + 10)
    return box.withLockedValue { $0 }
}
