import Foundation
import NIOCore
import TSFCAS
import TSFFutures
import llbuild2fx
import llbuild2
import TSCBasic
import AsyncHTTPClient
import NIOHTTP1

public struct FetchTitleResult: Codable {
    let pageTitle: String
}

extension FetchTitleResult: FXValue {}

public struct FetchTitle: AsyncFXKey, Encodable {
    public typealias ValueType = FetchTitleResult

    public static let versionDependencies: [FXVersioning.Type] = [FetchHTTP.self]
    
    let url: String

    public init(url: String) {
        self.url = url
    }
    
    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> FetchTitleResult {
        let str = try await fi.request(FetchHTTP(url: url), ctx).body
        
        let results = try RegEx(pattern: "<title>(.*)</title>").matchGroups(in: str)
        print(results)
        if let pageTitle = results.first?.first {
            return FetchTitleResult(pageTitle: pageTitle)
        } else {
            throw StringError("unhandled scenario")
        }
    }
}

