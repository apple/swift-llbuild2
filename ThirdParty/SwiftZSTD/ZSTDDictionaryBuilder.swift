//
//  ZSTDDictionaryBuilder.swift
//
//  Created by Anatoli on 12/06/16.
//  Copyright © 2016 Anatoli Peredera. All rights reserved.
//

import Foundation
import CZSTD

/**
 * Exceptions thrown by the dictionary builder.
 */
public enum ZDICTError : Error {
    case libraryError(errMsg : String)
    case unknownError
}

/**
 * Build a dictionary from samples identified by an array Data instances.
 *
 * The target dictionary size is 100th of the total sample size as 
 * recommended by documentation.
 *
 * - parameter  fromSamples : array of Data instances to use to build a dictionary
 * - returns: Data instance containing the dictionary generated
 */
public func buildDictionary(fromSamples : [Data]) throws -> Data {
    var samples = Data()
    var totalSampleSize : Int = 0;
    var sampleSizes = [Int]()
    
    for sample in fromSamples {
        samples.append(sample)
        totalSampleSize += sample.count
        sampleSizes.append(sample.count)
    }
    print ("totalSampleSize: \(totalSampleSize)")

    return try samples.withUnsafeBytes{ (pSamples : UnsafeRawBufferPointer) throws in
        let estimatedCount = totalSampleSize / 100
        var retVal = Data(count: estimatedCount)
        let actualCount = try retVal.withUnsafeMutableBytes{ (pDict : UnsafeMutableRawBufferPointer) -> Int in
            let actualDictSize = ZDICT_trainFromBuffer(pDict.baseAddress, estimatedCount, pSamples.baseAddress, &sampleSizes, UInt32(Int32(sampleSizes.count)))
            if ZDICT_isError(actualDictSize) != 0 {
                if let errStr = getDictionaryErrorString(actualDictSize) {
                    throw ZDICTError.libraryError(errMsg: errStr)
                } else {
                    throw ZDICTError.unknownError
                }
            } else {
                return actualDictSize
            }
        }
        retVal.count = actualCount
        return retVal
    }
}

/**
 * A helper to obtain error string.
 */
fileprivate func getDictionaryErrorString(_ rc : Int) -> String?
{
    if (ZDICT_isError(rc) != 0) {
        if let err = ZDICT_getErrorName(rc) {
            return String(bytesNoCopy: UnsafeMutableRawPointer(mutating: err), length: Int(strlen(err)), encoding: String.Encoding.ascii, freeWhenDone: false)
        }
    }
    return nil
}
