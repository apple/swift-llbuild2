// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import TSCBasic
import XCTest
import llbuild2fx

extension String: @retroactive FXRequestKey {
    public var stableHashValue: LLBDataID {
        return LLBDataID(blake3hash: self)
    }
}

final class FunctionCacheTests: XCTestCase {
    let group = LLBMakeDefaultDispatchGroup()

    /// ${TMPDIR} or just "/tmp", expressed as AbsolutePath
    private var temporaryPath: AbsolutePath {
        return try! AbsolutePath(validating: ProcessInfo.processInfo.environment["TMPDIR", default: "/tmp"])
    }

    func doFunctionCacheTests(cache: FXFunctionCache) throws {
        struct FakeProps: FXKeyProperties {
            var volatile: Bool = false
            var cachePath: String = "keypath"
        }
        let p = FakeProps()

        let ctx = Context()
        XCTAssertNil(try cache.get(key: "key1", props: p, ctx).wait())

        let id1 = LLBDataID(blake3hash: LLBByteBuffer.withBytes(ArraySlice("value1".utf8)), refs: [])
        try cache.update(key: "key1", props: p, value: id1, ctx).wait()
        XCTAssertEqual(id1, try cache.get(key: "key1", props: p, ctx).wait())
    }

    func testInMemoryFunctionCache() throws {
        let cache = FXInMemoryFunctionCache(group: group)
        try doFunctionCacheTests(cache: cache)
    }

    func testFileBackedFunctionCache() throws {
        try withTemporaryDirectory(dir: temporaryPath, prefix: "FXFunctionCacheTests" + #function, removeTreeOnDeinit: true) { tmpDir in
            let cache = FXFileBackedFunctionCache(group: group, path: tmpDir)
            try doFunctionCacheTests(cache: cache)
        }

    }
}
