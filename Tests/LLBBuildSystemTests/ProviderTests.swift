// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import XCTest

fileprivate struct SimpleProvider: LLBProvider {
    let simpleString: String
    
    init(simpleString: String) {
        self.simpleString = simpleString
    }
    
    init(from bytes: LLBByteBuffer) throws {
        self.simpleString = try String(from: bytes)
    }
    
    func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeString(simpleString)
    }
}

fileprivate struct OtherProvider: LLBProvider {
    let simpleString: String
    
    init(simpleString: String) {
        self.simpleString = simpleString
    }
    
    init(from bytes: LLBByteBuffer) throws {
        self.simpleString = try String(from: bytes)
    }
    
    func toBytes(into buffer: inout LLBByteBuffer) throws {
        buffer.writeString(simpleString)
    }
}

class ProviderTests: XCTestCase {
    func testProviderSerialization() throws {
        let provider = SimpleProvider(simpleString: "black lives matter")
        
        let providerMap = try LLBProviderMap(providers: [provider])
        let encoded = try providerMap.toBytes()
        let decodedProviderMap = try LLBProviderMap(from: encoded)
        
        XCTAssertEqual(decodedProviderMap, providerMap)
        
        let decodedProvider = try decodedProviderMap.get(SimpleProvider.self)
        XCTAssertEqual(decodedProvider.simpleString, "black lives matter")
    }
    
    func testMultipleProvidersError() throws {
        let provider1 = SimpleProvider(simpleString: "black lives matter")
        let provider2 = SimpleProvider(simpleString: "I can't breathe")
        
        XCTAssertThrowsError(try LLBProviderMap(providers: [provider1, provider2])) { error in
            guard let providerError = error as? LLBProviderMapError else {
                XCTFail("unexpected error type")
                return
            }
            guard case let .multipleProviders(providerType) = providerError else {
                XCTFail("unexpected error type")
                return
            }
            
            XCTAssertEqual(providerType, "SimpleProvider")
        }
    }
    
    func testDeterministicOutput() throws {
        let provider1 = SimpleProvider(simpleString: "black lives matter")
        let provider2 = OtherProvider(simpleString: "I can't breathe")
        
        let providerMap1 = try LLBProviderMap(providers: [provider1, provider2])
        let providerMap2 = try LLBProviderMap(providers: [provider1, provider2])
        XCTAssertEqual(try providerMap1.toBytes(), try providerMap2.toBytes())
    }
    
    func testUnknownProvider() throws {
        let providerMap = try LLBProviderMap(providers: [])
        XCTAssertThrowsError(try providerMap.get(SimpleProvider.self)) { error in
            guard let providerError = error as? LLBProviderMapError else {
                XCTFail("unexpected error type")
                return
            }
            guard case let .providerTypeNotFound(providerType) = providerError else {
                XCTFail("unexpected error type")
                return
            }
            
            XCTAssertEqual(providerType, "SimpleProvider")
        }
    }
}
