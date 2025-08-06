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

public struct ProcessExitExtendedInfo: Sendable {
    /// Reason the process exited.
    public var exitReason: ProcessExitReason

    /// Any errors that occurred whilst writing the provided `standardInput` sequence into the child process' standard input.
    public var standardInputWriteError: Optional<any Error>
}

public enum ProcessExitReason: Hashable & Sendable {
    case exit(CInt)
    case signal(CInt)

    public func throwIfNonZero() throws {
        switch self {
        case .exit(0):
            return
        default:
            throw ProcessExecutionError(self)
        }
    }
}

extension ProcessExitReason {
    /// Turn into an integer like `$?` works in shells.
    ///
    /// Concretely, this means if the program exits normally with exit code `N`, `asShellExitCode == N`. But if the program exits because of a signal, then
    /// `asShellExitCode == N + 128`, so 128 gets added to the signal number.
    public var asShellExitCode: Int {
        switch self {
        case .exit(let code):
            return Int(code)
        case .signal(let code):
            return 128 + Int(code)
        }
    }

    /// Turn into an integer like Python's subprocess does.
    ///
    /// Concretely, this means if the program exits normally with exit code `N`, `asShellExitCode == N`. But if the program exits because of a signal, then
    /// `asShellExitCode == -N`, so the negative signal number gets returned.
    public var asPythonExitCode: Int {
        switch self {
        case .exit(let code):
            return Int(code)
        case .signal(let code):
            return -Int(code)
        }
    }
}

public struct ProcessExecutionError: Error & Hashable & Sendable {
    public var exitReason: ProcessExitReason

    public init(_ exitResult: ProcessExitReason) {
        self.exitReason = exitResult
    }
}

extension ProcessExecutionError: CustomStringConvertible {
    public var description: String {
        return "process exited non-zero: \(self.exitReason)"
    }
}
