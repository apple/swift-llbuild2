@testable import MemoizedWebCrawler

import Foundation
import AsyncHTTPClient
import NIOCore
import TSFCAS
import TSFFutures
import llbuild2fx
import llbuild2
import TSCBasic
import Foundation

import XCTest

final class MemoizedWebCrawlerTests: XCTestCase {
    func testHTTP() async throws {
        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()
        
        // let db = LLBInMemoryCASDatabase(group: group)
        let db = LLBFileBackedCASDatabase(group: group, path: AbsolutePath("/tmp/my-cas/cas"))

        let functionCache = LLBFileBackedFunctionCache(group: group, path: AbsolutePath("/tmp/my-cas/function-cache"), version: "0")

        let executor = FXLocalExecutor()
        
        let engine = FXBuildEngine(
            group: group,
            db: db,
            functionCache: functionCache,
            executor: executor
        )
        let results = try await engine.build(key: FetchTitle(url: "http://example.com/"), ctx).get()
        XCTAssertEqual(results.pageTitle, "Example Domain")
    }
}