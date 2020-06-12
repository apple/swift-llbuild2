// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBBuildSystem
import Foundation
import llbuild2

/// A simple structure containing the initial state for the board at generation 0.
struct InitialBoard: Codable {
    let points: [Point]

    func isAlive(_ point: Point) -> Bool {
        return Set(points).contains(point)
    }
}

/// The configuration key represents the minimum amount of data needed to construct a full configuration fragment. For
/// Conways purpose, we just need to store the initial board state and the size of the board. All cell and board targets
/// at any generation derived from to this initial state.
struct ConwayConfigurationKey: LLBConfigurationFragmentKey, Codable {
    static let identifier = String(describing: Self.self)

    let initialBoard: InitialBoard
    let size: Point

    init(initialBoard: InitialBoard, size: Point) {
        self.initialBoard = initialBoard
        self.size = size
    }
}

/// The configuration fragment for the configuration key. For Conway, since the key is mostly static data, the fragment
/// just copies the values from the keys.
struct ConwayConfigurationFragment: LLBConfigurationFragment, Codable {
    let initialBoard: InitialBoard
    let size: Point

    init(initialBoard: InitialBoard, size: Point) {
        self.initialBoard = initialBoard
        self.size = size
    }

    /// Convenience constructor for the fragment from the key.
    static func fromKey(_ key: ConwayConfigurationKey) -> ConwayConfigurationFragment {
        return Self.init(initialBoard: key.initialBoard, size: key.size)
    }
}

/// The configuration key to configuration fragment function. Since the key has mostly static data, the function just
/// copies the results into the fragment.
class ConwayConfigurationFunction: LLBBuildFunction<ConwayConfigurationKey, ConwayConfigurationFragment> {
    override func evaluate(key: ConwayConfigurationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<ConwayConfigurationFragment> {
        return fi.group.next().makeSucceededFuture(.fromKey(key))
    }
}
