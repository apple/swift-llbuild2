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

/// A BoardTarget represents a target for a complete board. The size of the board is specified in the configuration for
/// the build, which is passed to the target lookup method in `with(key:_:)`. This target will be populated with all of
/// the cell targets for the requested generation.
struct BoardTarget: LLBConfiguredTarget, Codable {
    /// The provider map for each of the dependencies declared for this target. Provider maps are the interface for
    /// reading the evaluation outputs of dependency targets.
    let dependencies: [LLBLabel]

    init(dependencies: [LLBLabel]) {
        self.dependencies = dependencies
    }

    var targetDependencies: [String: LLBTargetDependency] {
        return ["dependencies": .list(dependencies)]
    }

    /// Constructor for a BoardTarget from the ConfigurationTargetKey.
    static func with(key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface, _ ctx: Context) throws -> LLBFuture<BoardTarget> {
        // Board labels are defined as //board:<generation>, since that's all that needed to reference a board at a
        // specific generation (i.e. the target).
        let label = key.label
        let generation = Int(label.targetName)!

        // This target is evaluated with a GameOfLifeConfigurationKey containing the global parameters of the build, like the
        // size of the board and the initial state.
        let boardSize = try key.configurationKey.get(GameOfLifeConfigurationKey.self).size

        var dependencies = [LLBLabel]()

        // Request the cell dependendency for each of the points in the board. This will effectively trigger the
        // evaluation of those targets and rules in order to provided the ProviderMap for each of the cell targets.
        // Once those are evaluated, the build system will be unblocked to evaluate this target.
        for x in 0..<boardSize.x {
            for y in 0..<boardSize.y {
                let dependencyLabel = try LLBLabel("//cell/\(generation):\(x)-\(y)")
                dependencies.append(dependencyLabel)
            }
        }

        return ctx.group.next().makeSucceededFuture(BoardTarget(dependencies: dependencies))
    }
}

/// BoardProvider is how BoardTargets communicate their state to dependents. It contains a single artifact reference
/// which when resolved will contain a matrix of `0` for dead cells and `1` for alive cells.
struct BoardProvider: LLBProvider, Codable {
    let board: LLBArtifact

    init(board: LLBArtifact) {
        self.board = board
    }
}

/// The rule implementation that processes a BoardTarget under the given configuration. Because cell dependencies were
/// already resolved at the BoardTarget creation time, we just need to read the CellProviders for each cell, order them
/// in a matrix form and then register an action that reads all the files and concatenates them into the matrix form
/// expected in the output.
class BoardRule: LLBBuildRule<BoardTarget> {
    override func evaluate(configuredTarget: BoardTarget, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        let dependencies: [CellProvider] = try ruleContext.getProviders(for: "dependencies")

        // Make a dictionary lookup of the cell's point to the artifact containing that state.
        let boardMap = dependencies.reduce(into: [:]) { (dict, dep) in dict[dep.position] = dep.state }

        let boardSize = try ruleContext.getFragment(GameOfLifeConfigurationFragment.self).size

        var matrix = [[LLBArtifact]]()

        // Go over the complete board finding the state artifact for each point, and add them as rows into the matrix.
        // Since we requested a dependency on the cell for each point, the boardMap will contain an artifact for each
        // point.
        for y in 0..<boardSize.y {
            matrix.append((0..<boardSize.x).map { x in boardMap[Point(x, y)]! })
        }

        // Declare the output artifact for the board. Declared artifacts are namespaced to the active configuration and
        // label, so there is no risk of collision for this artifact between other BoardTargets.
        let board = try ruleContext.declareArtifact("board.txt")

        // Create a "matrix" of `cat` commands that output each of the cells' state.
        let catCommands = matrix.map { row in
            "cat \(row.map(\.path).joined(separator: " ")) >> \(board.path); echo \"\" >> \(board.path)"
        }.joined(separator: "\n")

        // Register the action that populates the output board artifact.
        try ruleContext.registerAction(
            arguments: [
                "/bin/bash", "-c",
                """
                echo "" > \(board.path)
                \(catCommands)
                """,
            ],
            inputs: Array(boardMap.values),
            outputs: [board],
            mnemonic: "BoardTask",
            description: "Evaluating board \(ruleContext.label.canonical)..."
        )

        // Return the BoardProvider containing the board artifact so that dependents can read it and use it accordingly.
        return ruleContext.group.next().makeSucceededFuture(
            [BoardProvider(board: board)]
        )
    }
}
