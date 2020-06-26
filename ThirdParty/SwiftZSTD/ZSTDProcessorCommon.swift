//
//  ZSTDProcessorCommon.swift
//
//  Created by Anatoli on 12/06/16.
//  Copyright © 2016 Anatoli Peredera. All rights reserved.
//

import Foundation
import llbuild2CZSTD

/**
 * An extension providing a method to determine if the bytes of a Data are stored
 * in contiguous memory.
 */
extension Data
{
    func ZSTDIsContiguousData() -> Bool {
        return (self.regions.count == 1)
    }
}

/**
 * Types of exceptions thrown by the wrapper.
 */
public enum ZSTDError : Error {
    case libraryError(errMsg : String)
    case inputNotContiguous
    case decompressedSizeUnknown
    case invalidCompressionLevel(level: Int)
    case unknownError
}

/**
 * Common functionality of a Swift wrapper around the ZSTD C library.  Only compression and
 * decompression of a buffer in memory is currently supported. Streaming mode and file 
 * compression/decompression are not yet supported, these can be added later.
 *
 * One of the tricks here is to minimize copying of the buffers being processed.  Also, the
 * Data instances provided as input must use contiguous storage.
 */
class ZSTDProcessorCommon
{
    let compCtx : OpaquePointer?
    let decompCtx : OpaquePointer?
    
    /**
     * Initializer.
     *
     * - parameter useContext : if true, create a context to speed up multiple operations.
     */
    init(useContext : Bool)
    {
        if (useContext)
        {
            compCtx = ZSTD_createCCtx()
            decompCtx = ZSTD_createDCtx()
        }
        else {
            compCtx = nil
            decompCtx = nil
        }
    }
    
    deinit {
        if (compCtx != nil) { ZSTD_freeCCtx(compCtx) }
        if (decompCtx != nil) { ZSTD_freeDCtx(decompCtx) }
    }
        
    /**
     * Compress a buffer. Input is sent to the C API without copying by using the 
     * Data.withUnsafeBytes() method.  The C API places the output straight into the newly-
     * created Data instance, which is possible because there are no other references
     * to the instance at this point, so calling withUnsafeMutableBytes() does not trigger
     * a copy-on-write.
     * 
     * - parameter dataIn : input Data
     * - parameter delegateFunction : a specific function/closure to be called
     * - returns: compressed frame
     */
    func compressBufferCommon(_ dataIn : Data,
                              _ delegateFunction : (UnsafeMutableRawPointer,
                                                    Int,
                                                    UnsafeRawPointer,
                                                    Int)->Int ) throws -> Data
    {
        guard dataIn.ZSTDIsContiguousData() else {
            throw ZSTDError.inputNotContiguous
        }

        return try dataIn.withUnsafeBytes{ (pIn : UnsafeRawBufferPointer) throws in
            let expectedCount = ZSTD_compressBound(dataIn.count)
            var retVal = Data(count: expectedCount)
            let actualCount = try retVal.withUnsafeMutableBytes{ (pOut: UnsafeMutableRawBufferPointer) throws -> Int in
                let rc = delegateFunction(pOut.baseAddress!, expectedCount, pIn.baseAddress!, pIn.count)
                if let errStr = getProcessorErrorString(rc) {
                    throw ZSTDError.libraryError(errMsg: errStr)
                } else {
                    return rc
                }
            }
            retVal.count = actualCount
            return retVal
        }
    }

    /**
     * Decompress a frame that resulted from a previous compression of a buffer by ZSTD.
     * The exact frame size must be known, which is available via the
     * ZSTD_getDecompressedSize() API call.
     *
     * - parameter dataIn: frame to be decompressed
     * - parameter delegateFunction: closure/function to perform specific decompression work
     * - returns: a Data instance wrapping the decompressed buffer
     */
    func decompressFrameCommon(_ dataIn : Data,
                              _ delegateFunction : (UnsafeMutableRawPointer,
                                                    Int,
                                                    UnsafeRawPointer,
                                                    Int)->Int ) throws -> Data
    {
        guard dataIn.ZSTDIsContiguousData() else {
            throw ZSTDError.inputNotContiguous
        }
        
        var storedDSize : UInt64 = 0
        try dataIn.withUnsafeBytes { (p : UnsafeRawBufferPointer) throws in
            storedDSize = ZSTD_getDecompressedSize(p.baseAddress, p.count)
        }

        guard storedDSize != 0 else {
            throw ZSTDError.decompressedSizeUnknown
        }
        
        var retVal = Data(count: Int(storedDSize))
        
        try dataIn.withUnsafeBytes{ (pIn : UnsafeRawBufferPointer) in
            try retVal.withUnsafeMutableBytes{ (pOut : UnsafeMutableRawBufferPointer) throws in
                let rc = delegateFunction(pOut.baseAddress!, Int(storedDSize), pIn.baseAddress!, pIn.count)
                if ZSTD_isError(rc) != 0 {
                    if let errStr = getProcessorErrorString(rc) {
                        throw ZSTDError.libraryError(errMsg: errStr)
                    } else {
                        throw ZSTDError.unknownError
                    }
                }
            }
        }
        
        return retVal
    }
}

/**
 * A helper function to get the error string corresponding to an error code.
 * 
 * - parameter ec: error code
 * - returns: optional String matching the error code
 */
func getProcessorErrorString(_ ec : Int) -> String?
{
    if (ZSTD_isError(ec) != 0) {
        if let err = ZSTD_getErrorName(ec) {
            return String(bytesNoCopy: UnsafeMutableRawPointer(mutating: err), length: Int(strlen(err)), encoding: String.Encoding.ascii, freeWhenDone: false)
        }
    }
    return nil
}

/**
 * A helper to validate compression level.  A valid compression level is positive and
 * does not exceed the max value provided by the ZSTD C library.
 *
 * - parameter compressionLevel : compression level to validate
 * - returns: true if compression level is valid
 */
func isValidCompressionLevel(_ compressionLevel : Int) -> Bool {
    return compressionLevel >= 1 && compressionLevel <= ZSTD_maxCLevel()
}
