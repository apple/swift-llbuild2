// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import SwiftUI
import LLBBuildSystem
import Dispatch
import llbuild2

/// Environment object with a reference to the engine and database.
class GameOfLifeEnvironment: ObservableObject {
    let engine: LLBBuildEngine

    let ctx: Context

    /// Storage of the initial board to use when constructing the GenerationKey for each generation.
    var initialBoard: InitialBoard? = nil

    init(engine: LLBBuildEngine, _ ctx: Context) {
        self.engine = engine
        self.ctx = ctx
    }
}

struct GameOfLifeView: View {
    @EnvironmentObject
    var environment: GameOfLifeEnvironment

    @State
    var boardState = Set<Point>()

    @State
    var updateTime = 0.0

    @State
    var generation = 0

    @State
    var gridSize = 10

    @State
    var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generation \(self.generation)\(self.boardState.isEmpty ? " (No Life)" : "")")
                    .padding()
                Text(self.generation == 0 ? "(Edit Mode)" : "")
            }
            ForEach(0..<self.gridSize) { x in
                HStack(spacing: 0) {
                    ForEach(0..<self.gridSize) { y in
                        Rectangle()
                            .frame(width: 20, height: 20)
                            .foregroundColor(self.boardState.contains(Point(x, y)) ? .black : .white)
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                            .onTapGesture {
                                // Only allow edit on generation 0.
                                guard self.generation == 0 && !self.loading else {
                                    return
                                }
                                if self.boardState.contains(Point(x, y)) {
                                    self.boardState.remove(Point(x,y))
                                } else {
                                    self.boardState.insert(Point(x,y))
                                }
                            }
                    }
                }
            }
            HStack {
                Button(action: self.devolve) {
                    Text("Devolve")
                }
                    .padding()
                    .disabled(self.loading || self.generation == 0)
                Button(action: self.evolve) {
                    Text("Evolve")
                }
                    .padding()
                    .disabled(self.loading || self.boardState.isEmpty)
            }
            Text("Elapsed: \(updateTime)s")
        }
        .frame(minWidth: 600, minHeight: 550)
    }

    private func evolve() {
        if generation == 0 {
            // If evolving from generation 0, store the current board state as the initial state and then advance.
            environment.initialBoard = InitialBoard(points: Array(boardState).sorted(by: <))
        }
        generation += 1

        updateBoard()

    }

    private func devolve() {
        if generation > 0 {
            generation -= 1
        }
        if generation == 0 {
            // If devolving to generation 0, restore the initial state.
            boardState = Set(environment.initialBoard!.points)
        } else {
            updateBoard()
        }
    }

    private func updateBoard() {
        // Construct the GenerationKey to request to the build engine.
        let generationKey = GenerationKey(
            initialBoard: environment.initialBoard!,
            size: Point(gridSize, gridSize),
            generation: generation
        )

        self.loading = true
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer {
                DispatchQueue.main.async {
                    self.loading = false
                }
            }

            let generationValue: Set<Point>
            let elapsedS: Double
            do {
                let start = DispatchTime.now()
                generationValue = try environment.engine.build(generationKey, environment.ctx).flatMap { (value: GenerationValue) in
                    // Read the output data from the CAS.
                    return LLBCASFSClient(environment.ctx.db).load(value.boardID, environment.ctx).flatMap { node in
                        return node.blob!.read(environment.ctx).map { Data($0) }
                    }
                }.map { (data: Data) in
                    // Process the data as a 0s and 1s matrix where 1s signal alive cells, so add them to the
                    // boardState.
                    let boardString = String(data: data, encoding: .utf8)!
                    let lines = boardString.split(separator: "\n")
                    var boardState = Set<Point>()
                    for y in 0 ..< self.gridSize {
                        for x in 0 ..< self.gridSize {
                            if Array(lines[y])[x] == "1" {
                                boardState.insert(Point(x, y))
                            }
                        }
                    }
                    return boardState
                }.wait()
                let finish = DispatchTime.now()
                elapsedS = Double(finish.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

                DispatchQueue.main.async {
                    self.boardState = generationValue
                    self.updateTime = elapsedS
                }
            } catch {
                print("Error evaluating: \(error)")
            }
        }
    }
}
