// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem

/// GenerationKey represents the request for a board at a particular generation
/// for a given board size and initial state.
struct GenerationKey: LLBBuildKey, Codable, Hashable {
    let initialBoard: InitialBoard
    let size: Point
    let generation: Int

    init(initialBoard: InitialBoard, size: Point, generation: Int) {
        self.initialBoard = initialBoard
        self.size = size
        self.generation = generation
    }
}

/// GenerationValue corresponds to the result of evaluating a GenerationKey, and
/// contains a data ID pointer to the data that represents the board for the
/// specified generation key.
struct GenerationValue: LLBBuildValue, Codable {
    let boardID: LLBDataID

    init(boardID: LLBDataID) {
        self.boardID = boardID
    }
}

class GenerationFunction: LLBBuildFunction<GenerationKey, GenerationValue> {
    override func evaluate(key: GenerationKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<GenerationValue> {
        do {
            // Construct the GameOfLife configuration key with the initial board and board size.
            let configurationKey = try LLBConfigurationKey(
                fragmentKeys: [GameOfLifeConfigurationKey(initialBoard: key.initialBoard, size: key.size)]
            )

            // Request the BoardTarget for the specified generation, with the configuration key.
            let configuredTargetKey = LLBConfiguredTargetKey(
                rootID: LLBDataID(),
                label: try LLBLabel("//board:\(key.generation)"),
                configurationKey: configurationKey
            )

            // Request the evaluation of the board target and retrieve the
            // BoardProvider's board artifact.
            return fi.requestDependency(configuredTargetKey).flatMap { providerMap in
                do {
                    let artifact = try providerMap.get(BoardProvider.self).board
                    // Request the board artifact to evaluate and trigger action execution.
                    return fi.requestArtifact(artifact)
                } catch {
                    return fi.group.next().makeFailedFuture(error)
                }
            }.map { (artifactValue: LLBArtifactValue) in
                // With the data ID for the artifact, return the GenerationValue.
                return GenerationValue(boardID: artifactValue.dataID)
            }
        } catch {
            return fi.group.next().makeFailedFuture(error)
        }
    }
}

