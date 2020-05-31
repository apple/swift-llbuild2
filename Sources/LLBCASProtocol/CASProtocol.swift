// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import llbuild2


public extension LLBDataID {
    var asProto: LLBPBDataID {
        return LLBPBDataID.with { $0.bytes = Data(self.bytes) }
    }
}

public extension LLBPBDataID {
    init(_ dataID: LLBDataID) {
        self = Self.with {
            $0.bytes = Data(dataID.bytes)
        }
    }
}

public extension LLBCASObject {
    var asProto: LLBPBCASObject {
        var pb = LLBPBCASObject()
        pb.refs = self.refs.map { $0.asProto }
        pb.data = [Data(self.data.getBytes(at: 0, length: self.data.readableBytes)!)]
        return pb
    }
}
