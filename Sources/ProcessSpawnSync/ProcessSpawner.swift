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

import Atomics
import CProcessSpawnSync
import NIOConcurrencyHelpers

#if os(iOS) || os(tvOS) || os(watchOS)
  // Process & fork/exec unavailable
    #error("Process and fork() unavailable")
#else
    import Foundation
#endif

extension ps_error_s {
    private func makeDescription() -> String {
        return """
            PSError(\
            kind: \(self.pse_kind.rawValue), \
            errno: \(self.pse_code), \
            file: \(String(cString: self.pse_file)), \
            line: \(self.pse_line)\
            \(self.pse_extra_info != 0 ? ", extra: \(self.pse_extra_info)" : ""
               )
            """
    }
}

#if compiler(>=6.0)
    extension ps_error_s: @retroactive CustomStringConvertible {
        public var description: String {
            return self.makeDescription()
        }
    }
#else
    extension ps_error_s: CustomStringConvertible {
        public var description: String {
            return self.makeDescription()
        }
    }
#endif

public struct PSProcessUnknownError: Error & CustomStringConvertible {
    var reason: String

    public var description: String {
        return self.reason
    }
}

// We need this to replicate `Foundation.Process`'s odd API where
// - stardard{Input,Output,Error} not set means _inherit_
// - stardard{Input,Output,Error} set to `nil` means `/dev/null`
// - stardard{Input,Output,Error} set to FileHandle/Pipe means use that
internal enum OptionallySet<Wrapped> {
    case notSet
    case setToNone
    case setTo(Wrapped)

    var asOptional: Wrapped? {
        switch self {
        case .notSet:
            return nil
        case .setToNone:
            return nil
        case .setTo(let wrapped):
            return wrapped
        }
    }

    var isSetToNone: Bool {
        switch self {
        case .notSet, .setTo:
            return false
        case .setToNone:
            return true
        }
    }
}

extension OptionallySet: Sendable where Wrapped: Sendable {}

public final class PSProcess: Sendable {
    struct State: Sendable {
        var executableURL: URL? = nil
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var currentDirectoryURL: URL? = nil
        var closeOtherFileDescriptors: Bool = true
        var createNewSession: Bool = false
        private(set) var pidWhenRunning: pid_t? = nil
        var standardInput: OptionallySet<Pipe> = .notSet
        var standardOutput: OptionallySet<FileHandle> = .notSet
        var standardError: OptionallySet<FileHandle> = .notSet
        var terminationHandler: (@Sendable (PSProcess) -> Void)? = nil
        private(set) var procecesIdentifier: pid_t? = nil
        private(set) var terminationStatus: (Process.TerminationReason, CInt)? = nil

        mutating func setRunning(pid: pid_t, isRunningApproximation: ManagedAtomic<Bool>) {
            assert(self.pidWhenRunning == nil)
            self.pidWhenRunning = pid
            self.procecesIdentifier = pid
            isRunningApproximation.store(true, ordering: .relaxed)
        }

        mutating func setNotRunning(
            terminationStaus: (Process.TerminationReason, CInt),
            isRunningApproximation: ManagedAtomic<Bool>
        ) -> @Sendable (PSProcess) -> Void {
            assert(self.pidWhenRunning != nil)
            isRunningApproximation.store(false, ordering: .relaxed)
            self.pidWhenRunning = nil
            self.terminationStatus = terminationStaus
            let terminationHandler = self.terminationHandler ?? { _ in }
            self.terminationHandler = nil
            return terminationHandler
        }
    }

    let state = NIOLockedValueBox(State())
    let isRunningApproximation = ManagedAtomic(false)

    public init() {}

    public func run() throws {
        let state = self.state.withLockedValue { $0 }

        guard let pathString = state.executableURL?.path.removingPercentEncoding else {
            throw PSProcessUnknownError(reason: "executableURL is nil")
        }
        let cwdString = state.currentDirectoryURL?.path.removingPercentEncoding
        let path = copyOwnedCTypedString(pathString)
        defer {
            path.deallocate()
        }
        let cwd = cwdString.map { copyOwnedCTypedString($0) }
        defer {
            cwd?.deallocate()
        }
        let args = copyOwnedCTypedStringArray([pathString] + state.arguments)
        defer {
            var index = 0
            var arg = args[index]
            while arg != nil {
                arg!.deallocate()
                index += 1
                arg = args[index]
            }
        }
        let envs = copyOwnedCTypedStringArray((state.environment.map { k, v in "\(k)=\(v)" }))
        defer {
            var index = 0
            var env = envs[index]
            while env != nil {
                env!.deallocate()
                index += 1
                env = envs[index]
            }
        }

        let devNullFD: CInt
        if state.standardInput.isSetToNone || state.standardOutput.isSetToNone || state.standardError.isSetToNone {
            devNullFD = open("/dev/null", O_RDWR)
            guard devNullFD >= 0 else {
                throw PSProcessUnknownError(reason: "Cannot open /dev/null: \(errno)")
            }
        } else {
            devNullFD = -1
        }

        defer {
            if devNullFD != -1 {
                close(devNullFD)
            }
        }
        let stdinFDForChild: CInt
        let stdoutFDForChild: CInt
        let stderrFDForChild: CInt

        // Replicate `Foundation.Process`'s API where not setting means "inherit" and `nil`-setting means /dev/null
        switch state.standardInput {
        case .notSet:
            stdinFDForChild = STDIN_FILENO
        case .setToNone:
            assert(devNullFD >= 0)
            stdinFDForChild = devNullFD
        case .setTo(let handle):
            stdinFDForChild = handle.fileHandleForReading.fileDescriptor
        }

        switch state.standardOutput {
        case .notSet:
            stdoutFDForChild = STDOUT_FILENO
        case .setToNone:
            assert(devNullFD >= 0)
            stdoutFDForChild = devNullFD
        case .setTo(let handle):
            stdoutFDForChild = handle.fileDescriptor
        }

        switch state.standardError {
        case .notSet:
            stderrFDForChild = STDERR_FILENO
        case .setToNone:
            assert(devNullFD >= 0)
            stderrFDForChild = devNullFD
        case .setTo(let handle):
            stderrFDForChild = handle.fileDescriptor
        }

        let psSetup: [ps_fd_setup] = [
            ps_fd_setup(psfd_kind: PS_MAP_FD, psfd_parent_fd: stdinFDForChild),
            ps_fd_setup(psfd_kind: PS_MAP_FD, psfd_parent_fd: stdoutFDForChild),
            ps_fd_setup(psfd_kind: PS_MAP_FD, psfd_parent_fd: stderrFDForChild),
        ]
        let (pid, error) = psSetup.withUnsafeBufferPointer { psSetupPtr -> (pid_t, ps_error) in
            var config = ps_process_configuration_s(
                psc_path: path,
                psc_argv: args,
                psc_env: envs,
                psc_cwd: cwd,
                psc_fd_setup_count: CInt(psSetupPtr.count),
                psc_fd_setup_instructions: psSetupPtr.baseAddress!,
                psc_new_session: state.createNewSession,
                psc_close_other_fds: state.closeOtherFileDescriptors
            )
            var error = ps_error()
            let pid = ps_spawn_process(&config, &error)
            return (pid, error)
        }
        switch state.standardInput {
        case .notSet, .setToNone:
            ()  // Nothing to do
        case .setTo(let pipe):
            try! pipe.fileHandleForReading.close()
        }
        guard pid > 0 else {
            switch (error.pse_kind, error.pse_code) {
            case (PS_ERROR_KIND_EXECVE, ENOENT),
                (PS_ERROR_KIND_EXECVE, ENOTDIR),
                (PS_ERROR_KIND_CHDIR, ENOENT),
                (PS_ERROR_KIND_CHDIR, ENOTDIR):
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileNoSuchFileError,
                    userInfo: ["underlying-error": "\(error)"]
                )
            default:
                throw PSProcessUnknownError(reason: "\(error)")
            }
        }
        self.state.withLockedValue { state in
            state.setRunning(pid: pid, isRunningApproximation: self.isRunningApproximation)
        }

        let q = DispatchQueue(label: "q")
        let source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: q)
        source.setEventHandler {
            if let terminationHandler = self.terminationHandlerFinishedRunning() {
                source.cancel()
                terminationHandler(self)
            }
        }
        source.setRegistrationHandler {
            if let terminationHandler = self.terminationHandlerFinishedRunning() {
                source.cancel()
                q.async {
                    terminationHandler(self)
                }
            }
        }
        source.resume()
    }

    public var processIdentifier: pid_t {
        return self.state.withLockedValue { state in
            return state.procecesIdentifier!
        }
    }

    public var terminationReason: Process.TerminationReason {
        return self.state.withLockedValue { state in
            state.terminationStatus!.0
        }
    }

    public var terminationStatus: CInt {
        return self.state.withLockedValue { state in
            state.terminationStatus!.1
        }
    }

    public var isRunning: Bool {
        return self.isRunningApproximation.load(ordering: .relaxed)
    }

    internal func terminationHandlerFinishedRunning() -> (@Sendable (PSProcess) -> Void)? {
        return self.state.withLockedValue { state -> (@Sendable (PSProcess) -> Void)? in
            guard let pid = state.pidWhenRunning else {
                return nil
            }
            var status: CInt = -1
            while true {
                let err = waitpid(pid, &status, WNOHANG)
                if err == -1 {
                    if errno == EINTR {
                        continue
                    } else {
                        preconditionFailure("waitpid failed with \(errno)")
                    }
                } else {
                    var hasExited = false
                    var isExitCode = false
                    var code: CInt = 0
                    ps_convert_exit_status(status, &hasExited, &isExitCode, &code)
                    if hasExited {
                        return state.setNotRunning(
                            terminationStaus: (isExitCode ? .exit : .uncaughtSignal, code),
                            isRunningApproximation: self.isRunningApproximation
                        )
                    } else {
                        return nil
                    }
                }
            }
        }
    }

    public var executableURL: URL? {
        get {
            self.state.withLockedValue { state in
                state.executableURL
            }
        }
        set {
            self.state.withLockedValue { state in
                state.executableURL = newValue
            }
        }
    }

    public var currentDirectoryURL: URL? {
        get {
            self.state.withLockedValue { state in
                state.currentDirectoryURL
            }
        }
        set {
            self.state.withLockedValue { state in
                state.currentDirectoryURL = newValue
            }
        }
    }

    public var launchPath: String? {
        get {
            self.state.withLockedValue { state in
                state.executableURL?.absoluteString
            }
        }
        set {
            self.state.withLockedValue { state in
                state.executableURL = newValue.map { URL(fileURLWithPath: $0) }
            }
        }
    }

    public var arguments: [String] {
        get {
            self.state.withLockedValue { state in
                state.arguments
            }
        }
        set {
            self.state.withLockedValue { state in
                state.arguments = newValue
            }
        }
    }

    public var environment: [String: String] {
        get {
            self.state.withLockedValue { state in
                state.environment
            }
        }
        set {
            self.state.withLockedValue { state in
                state.environment = newValue
            }
        }
    }

    public var standardOutput: FileHandle? {
        get {
            self.state.withLockedValue { state in
                state.standardOutput.asOptional
            }
        }
        set {
            self.state.withLockedValue { state in
                state.standardOutput = newValue.map { .setTo($0) } ?? .setToNone
            }
        }
    }

    public var standardError: FileHandle? {
        get {
            self.state.withLockedValue { state in
                state.standardError.asOptional
            }
        }
        set {
            self.state.withLockedValue { state in
                state.standardError = newValue.map { .setTo($0) } ?? .setToNone
            }
        }
    }

    public var standardInput: Pipe? {
        get {
            self.state.withLockedValue { state in
                state.standardInput.asOptional
            }
        }
        set {
            self.state.withLockedValue { state in
                state.standardInput = newValue.map { .setTo($0) } ?? .setToNone
            }
        }
    }

    public var terminationHandler: (@Sendable (PSProcess) -> Void)? {
        get {
            self.state.withLockedValue { state in
                state.terminationHandler
            }
        }
        set {
            self.state.withLockedValue { state in
                state.terminationHandler = newValue
            }
        }
    }

    public var _closeOtherFileDescriptors: Bool {
        get {
            self.state.withLockedValue { state in
                return state.closeOtherFileDescriptors
            }
        }
        set {
            self.state.withLockedValue { state in
                state.closeOtherFileDescriptors = newValue
            }
        }
    }

    public var _createNewSession: Bool {
        get {
            self.state.withLockedValue { state in
                return state.createNewSession
            }
        }
        set {
            self.state.withLockedValue { state in
                state.createNewSession = newValue
            }
        }
    }
}

func copyOwnedCTypedString(_ string: String) -> UnsafeMutablePointer<CChar> {
    let out = UnsafeMutableBufferPointer<CChar>.allocate(capacity: string.utf8.count + 1)
    _ = out.initialize(from: string.utf8.map { CChar(bitPattern: $0) })
    out[out.endIndex - 1] = 0

    return out.baseAddress!
}

func copyOwnedCTypedStringArray(_ array: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let out = UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: array.count + 1)
    for (index, string) in array.enumerated() {
        out[index] = copyOwnedCTypedString(string)
    }
    out[out.endIndex - 1] = nil

    return out.baseAddress!
}
