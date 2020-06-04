# llbuild2's Action Graph

This document explains how the action graph is modeled in llbuild2. There are 2
important pieces in the action graph, `Artifact`s and `ActionKey`s.

## `Artifact`

Artifacts represent a handle to a file system entity expected to be produced,
consumed, or both, during the execution of a build. In llbuild2, there are 2
main categories for artifacts: source artifacts and derived artifacts.

Source artifacts refer to the artifacts that are inputs into the build, and may
be any kind of file system entity that is part of your project. Some examples
for source artifacts include source code, like `.swift` files; resources, like
`xcassets` bundles; or in general, any kind of entity that would be checked in
into a git repository that can't be derived in any way. Source artifacts in
llbuild2 are represented by the CAS data ID as returned by a CAS database. This
data ID acts as both a uniqueness identifier (2 artifacts with the same dataID
contain the same contents) and as a handle to retrieve the data from the
database (`database.get(dataID) -> data`).

Derived artifacts on the other hand, are artifacts that are produced during the
build, which may be the final artifacts that you expect from the build (like a
compiled and linked executable) or intermediate artifacts that are not as useful
by themselves, but are combined into other derived artifacts to produce more
useful results. In llbuild2, most derived artifacts are represented by the
dataID of the producing entity, like an ActionKey.

## `ActionKey`

Action keys represent the transformation of an arbitrary set of artifacts inputs
into a new set of artifact outputs. llbuild2 currently supports command line
based action keys, where the transformation is effectively the execution of a
command line invocation on some execution environment, but action keys are
designed in an extensible manner to allow other types of transformations.

## Action Graph

In llbuild2, there are no specialized graph data structures to manage the action
graph, instead, it is the relationships between `Artifact` and `ActionKey` that
make up an implicit action graph. Because artifacts and action keys are
serialized into CAS databases, the scalability of the action graph is determined
by the available CAS database storage.

Take for example the following action graph:

```
            +------------+
            | executable |
            +------------+
                  |
           +--------------+
           | Link  Action |
           +--------------+
            |            |
      +--------+      +--------+
      | main.o |      | shrd.o |
      +--------+      +--------+
            |            |
     +----------+    +----------+
     | Compiler |    | Compiler |
     +----------+    +----------+
            |            |
      +--------+      +--------+
      | main.c |      | shrd.c |
      +--------+      +--------+
```

In llbuild2, this action graph would be represented as:

```
                             +------------+
                             |  Artifact  | .derived(0~abc...)
                             +------------+
                                   |
                            +--------------+
                            |  Action Key  | 0~abc...
                            +--------------+
                             |            |
                      +----------+    +----------+
.derived(0~xnu..., 0) | Artifact |    | Artifact |  .derived(0~blm..., 0)
                      +----------+    +----------+
                             |            |
                    +------------+    +------------+
           0~xnu... | Action Key |    | Action Key | 0~blm...
                    +------------+    +------------+
                             |            |
                      +----------+    +----------+
    .source(0~llb...) | Artifact |    | Artifact | .source(0~ahb)
                      +----------+    +----------+
```

Where the derived artifacts have a data ID pointer to the action key that
produces the artifact, and the action keys have artifact pointers to the input
artifacts. It is interesting to notice that since the graph references are data
IDs, which represent a digest of the contents of the graphs' nodes, the action
graph actually represents a Merkle tree.

If for example main.c has changed, then it's data ID would necessarily be
different, and that would result in a completely new action graph with a new
root. But since the sub-graph that depends on shrd.c hasn't changed, that
sub-graph would be shared among the old and the new action graphs. This allows
for minimizing the CAS storage usage since we only need to store the pieces that
have changed, and not a completely new action graph.

## Action execution

There is another aspect of the action graph which is its computation in order
to build the requested artifact. Since any source change invalidates all of the
ActionKeys that transitively depend on it, that would mean that the ActionKeys
for downstream dependents would also be evaluated during a build. In order to
avoid reëxecuting actions excessively, the `ActionFunction` requests the
evaluation of all the inputs for the action, and constructs an
`ActionExecutionKey`, in which the inputs are specified as the actual data ID
for the contents of the artifact.

At this stage, llbuild2 can check its cache to check whether that particular
`ActionExecutionKey` has been evaluated before, and return the cached results if
so. This architecture allows llbuild2 to avoid excessive recomputations of the
inputs for an action haven't changed.

As an example, if we modify `main.c` above to add a comment, the newly compiled
`main.o` would be no different from the previosly compiled `main.o` (assuming
the compilation action is deterministic). That would mean that the
`ActionExecutionKey`s being evaluated downstream would effectively be cached,
resulting in faster builds.