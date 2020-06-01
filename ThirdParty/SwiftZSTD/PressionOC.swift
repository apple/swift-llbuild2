//
//  Copyright © 2018 Apple, Inc. All rights reserved.
//
import Foundation

class PressionOC {
    private var inProgress_ = false

    /// Whether compressor/decompressor has been initiated.
    var inProgress: Bool {
        get { return inProgress_ }
        set { inProgress_ = newValue }
    }

    enum Result {
    case data(Data)
    case error(code: Int)
    }

    internal enum AppendResult {
    case appended(count: Int)
    case error(code: Int)
    }

    init?() { }
}

public protocol WriteAdvanceableBuffer {
    mutating func reserveWriteCapacity(_ count: Int)
    mutating func unsafeWrite<R>(_ writeCallback: (UnsafeMutableRawBufferPointer) -> (wrote: Int, R)) -> R
}
