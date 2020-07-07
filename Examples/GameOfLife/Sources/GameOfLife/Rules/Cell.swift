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

/// Simple 2D point struct.
struct Point: Codable, Hashable, Comparable {
    let x: Int
    let y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    static func < (lhs: Point, rhs: Point) -> Bool {
        if lhs.x == rhs.x {
            return lhs.y < rhs.y
        }
        return lhs.x < rhs.x
    }
}

/// A CellTarget represents the cell at a particular generation. It has a dependency to its same cell at a previous
/// generation, along with dependencies to the neighbours at the previous generation.
struct CellTarget: LLBConfiguredTarget, Codable {
    let position: Point
    let generation: Int
    let previousState: LLBLabel?
    let neighbours: [LLBLabel]

    init(position: Point, generation: Int, previousState: LLBLabel?, neighbours: [LLBLabel]) {
        self.position = position
        self.generation = generation
        self.previousState = previousState
        self.neighbours = neighbours
    }
    
    var targetDependencies: [String : LLBTargetDependency] {
        var targetDependencies = ["neighbours": LLBTargetDependency.list(neighbours)]
        if let previousState = previousState {
            targetDependencies["previousState"] = .single(previousState)
        }
        return targetDependencies
    }

    /// Constructor for a CellTarget from the configuration key.
    static func with(key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) throws -> LLBFuture<CellTarget> {
        // CellTarget labels are defined as //cell/<generation>:<x>-<y>.
        let label = key.label
        let generation = Int(label.logicalPathComponents[1])!
        let positionCoords = label.targetName.split(separator: "-").map { Int($0)! }
        let position = Point(positionCoords[0], positionCoords[1])

        // Generation 0 has no dependencies, so return it with just its position and generation. Configured targets are
        // about definining what to build, not how. While we could in theory just read the initial state from the
        // configuration in the configuration key, just for generation 0, that's really the job of the rule evaluation.
        if generation == 0 {
            return ctx.group.next().makeSucceededFuture(
                CellTarget(position: position, generation: generation, previousState: nil, neighbours: [])
            )
        }

        let boardSize = try key.configurationKey.get(GameOfLifeConfigurationKey.self).size

        var neighbours = [LLBLabel]()

        // Request the neighbour dependencies. Dependencies do not need to be ordered in any way, since the CellProvider
        // includes positioning information that the BoardRule uses to order the cells in the matrix.
        for x in (position.x - 1)...(position.x + 1) {
            for y in (position.y - 1)...(position.y + 1) {
                // Skip if the point is outside of the board or if the point is the current point, since the self
                // dependency comes later.
                if x < boardSize.x && x >= 0 && y < boardSize.y && y >= 0 && (position.x != x || position.y != y) {

                    let neighbourLabel = try LLBLabel("//cell/\(generation - 1):\(x)-\(y)")
                    neighbours.append(neighbourLabel)
                }
            }
        }

        // Request the dependency for the same point at the previous generation.
        let previousStateLabel = try LLBLabel("//cell/\(generation - 1):\(position.x)-\(position.y)")
        
        return ctx.group.next().makeSucceededFuture(
            CellTarget(
                position: position,
                generation: generation,
                previousState: previousStateLabel,
                neighbours: neighbours
            )
        )
    }
}

/// A CellProvider contains the result of evaluating a CellTarget, containing the position that the cell corresponds to
/// and the state artifact, which is a reference to a file containing 0 if the cell is dead or 1 if the cell is alive.
struct CellProvider: LLBProvider, Codable {
    let state: LLBArtifact
    let position: Point

    init(state: LLBArtifact, position: Point) {
        self.state = state
        self.position = position
    }
}

class CellRule: LLBBuildRule<CellTarget> {
    override func evaluate(configuredTarget: CellTarget, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        // Register the output artifact for the cell state.
        let stateArtifact = try ruleContext.declareArtifact("state.txt")

        // If the requested generation is 0, read the configuration's initial state and write the artifact statically.
        if configuredTarget.generation == 0 {
            let state: String
            if try ruleContext.getFragment(GameOfLifeConfigurationFragment.self).initialBoard.isAlive(configuredTarget.position) {
                state = "1"
            } else {
                state = "0"
            }

            try ruleContext.write(contents: state, to: stateArtifact)

            return ruleContext.group.next().makeSucceededFuture(
                [CellProvider(state: stateArtifact, position: configuredTarget.position)]
            )
        }

        // Get the list of neighbours state artifacts from the dependencies.
        let neighbours: [LLBArtifact] = try ruleContext.getProviders(for: "neighbours", as: CellProvider.self).map(\.state)
        // And also the previous state of the current position.
        let previousState = try ruleContext.getProvider(for: "previousState", as: CellProvider.self).state

        // Register a rule that processes the neighbours and the previous state according to Conway's Game of Life rules
        // and returns an output containing either a 1 or a 0 depending on whether the cell is alive or dead.
        try ruleContext.registerAction(
            arguments: [
                "/bin/bash", "-c",
                """
                neighbours=$(paste -d+ \(neighbours.map(\.path).joined(separator: " ")) | bc)
                if [ "$neighbours" -lt 2 ]; then
                    printf 0 > \(stateArtifact.path)
                elif [ "$neighbours" -gt 3 ]; then
                    printf 0 > \(stateArtifact.path)
                elif [ "$neighbours" -eq 3 ]; then
                    printf 1 > \(stateArtifact.path)
                else
                    cp -f \(previousState.path) \(stateArtifact.path)
                fi
                """
            ],
            inputs: neighbours + [previousState],
            outputs: [stateArtifact],
            mnemonic: "CellTask"
        )

        return ruleContext.group.next().makeSucceededFuture(
            [CellProvider(state: stateArtifact, position: configuredTarget.position)]
        )
    }
}
