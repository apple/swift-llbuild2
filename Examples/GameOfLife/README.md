# GameOfLife

An implementation of Conway's Game of Life using llbuild2's Build System
component.

To run, just open the project in Xcode and hit run. Alternatively,
`cd Examples/GameOfLife; swift run` should also work. This should open a SwiftUI
based application with a view of the board.

At generation 0, you can edit which cells are alive or dead by clicking on them,
and evolving the board will evaluate the dependency graph of cells to produce
the board state at the next generation.

This implementation of Conway's Game of Life is based on declaring cell
dependencies between surrounding cells at different generations, where the
computation for the next cell state is done using a bash command line
invocation.

## Notes

* There might be a bug in the blake3 implementation when building game_of_life
  with the `swift` command line tool which results in a segmentation fault. If it
  happens to you, please use Xcode to open the project instead, since that
  should avoid the issue.
