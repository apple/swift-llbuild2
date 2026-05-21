import Foundation
import NIOCore
import TSFCAS
import TSFFutures
import llbuild2fx
import llbuild2
import TSCBasic
import AsyncHTTPClient
import NIOHTTP1

public struct FetchHTTPResult: Codable {
    let body: String
}

extension FetchHTTPResult: FXValue {}

public struct FetchHTTP: AsyncFXKey, Encodable {
    public typealias ValueType = FetchHTTPResult

    public static let version: Int = 2
    public static let versionDependencies: [FXVersioning.Type] = []
    
    let url: String

    public init(url: String) {
        self.url = url
    }
    
    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> FetchHTTPResult {
        let client = LLBCASFSClient(ctx.db)

        let request = HTTPClientRequest(url: self.url)
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))

        if response.status == .ok {
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1 MB
            let str = String(buffer: body)
            return FetchHTTPResult(body: str)
        } else {
            throw StringError("response.status was not ok (\(response.status))")
        }
        throw StringError("unhandled scenario")
    }
}

