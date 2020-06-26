// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import Foundation

public enum LLBCASFSClientTestError: Error {
    case notFile
    case decodingError
}

extension LLBCASFSClient {
    /// Returns the String contents of a file for a specified LLBDataID. Throws if the dataID does not represent a file
    /// or if it can't be converted into a String.
    public func fileContents(for dataID: LLBDataID) throws -> String {
        let casFSClient = LLBCASFSClient(db)
        return try casFSClient.load(dataID).flatMap { [self] node in
            guard let blob = node.blob else {
                return db.group.next().makeFailedFuture(LLBCASFSClientTestError.notFile)
            }
            return blob.read().flatMapThrowing { data in
                guard let contents = String(data: Data(data), encoding: .utf8) else {
                    throw LLBCASFSClientTestError.decodingError
                }
                return contents
            }
        }.wait()
    }
}
