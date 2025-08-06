// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import LLBBuildSystem
import llbuild2

/// A simple structure containing the initial state for the board at generation 0.
struct InitialBoard: Codable, Hashable {
    let points: [Point]

    func isAlive(_ point: Point) -> Bool {
        return Set(points).contains(point)
    }
}

/// The configuration key represents the minimum amount of data needed to
/// construct a full configuration fragment. For GameOfLife purpose, we just need
/// to store the initial board state and the size of the board. All cell and
/// board targets at any generation derived from to this initial state.
struct GameOfLifeConfigurationKey: LLBConfigurationFragmentKey, Codable, Hashable {
    static let identifier = String(describing: Self.self)

    let initialBoard: InitialBoard
    let size: Point

    init(initialBoard: InitialBoard, size: Point) {
        self.initialBoard = initialBoard
        self.size = size
    }
}

/// The configuration fragment for the configuration key. For GameOfLife, since
/// the key is mostly static data, the fragment just copies the values from the
/// keys.
struct GameOfLifeConfigurationFragment: LLBConfigurationFragment, Codable {
    let initialBoard: InitialBoard
    let size: Point

    init(initialBoard: InitialBoard, size: Point) {
        self.initialBoard = initialBoard
        self.size = size
    }

    /// Convenience constructor for the fragment from the key.
    static func fromKey(_ key: GameOfLifeConfigurationKey) -> GameOfLifeConfigurationFragment {
        return Self.init(initialBoard: key.initialBoard, size: key.size)
    }
}

/// The configuration key to configuration fragment function. Since the key has
/// mostly static data, the function just copies the results into the fragment.
class GameOfLifeConfigurationFunction: LLBBuildFunction<GameOfLifeConfigurationKey, GameOfLifeConfigurationFragment> {
    override func evaluate(key: GameOfLifeConfigurationKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) -> LLBFuture<GameOfLifeConfigurationFragment> {
        return ctx.group.next().makeSucceededFuture(.fromKey(key))
    }
}
