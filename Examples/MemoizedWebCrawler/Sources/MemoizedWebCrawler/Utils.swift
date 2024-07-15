import Foundation
import NIOCore
import TSFCAS
import TSFFutures
import llbuild2fx
import llbuild2
import TSCBasic

extension LLBFileBackedFunctionCache: FXFunctionCache {
    public func get(key: llbuild2.LLBKey, props: llbuild2fx.FXKeyProperties, _ ctx: TSCUtility.Context) -> TSFFutures.LLBFuture<TSFCAS.LLBDataID?> {
        return get(key: key, ctx)
    }
    
    public func update(key: llbuild2.LLBKey, props: llbuild2fx.FXKeyProperties, value: TSFCAS.LLBDataID, _ ctx: TSCUtility.Context) -> TSFFutures.LLBFuture<Void> {
        return update(key: key, value: value, ctx)
    }
}
