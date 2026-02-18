import Logging
@preconcurrency import llbuild2fx


public protocol FXAuthorizationKey: FXKey where ValueType == FXAuthorizationResult {
    init(entrypoint: FXEntrypoint, _ ctx: Context) async throws
}

public struct FXAuthorizationResult: FXValue, Codable, Sendable {
    public let isAuthorized: Bool

    public let denialReason: String?

    public let metadata: [String: String]

    public init(isAuthorized: Bool, denialReason: String? = nil, metadata: [String: String] = [:]) {
        self.isAuthorized = isAuthorized
        self.denialReason = denialReason
        self.metadata = metadata
    }
}

public struct FXAuthorizationError: Error, CustomStringConvertible {
    public let result: FXAuthorizationResult

    public init(result: FXAuthorizationResult) {
        self.result = result
    }

    public var description: String {
        if let reason = result.denialReason {
            return "Authorization denied: \(reason)"
        }
        return "Authorization denied"
    }
}
