# Overview

## What is llbuild2?

llbuild2 is a functional, artifact-based and extensible build system framework designed for large scale projects,
focusing on maximizing the reusability of past evaluations. llbuild2 provides general abstractions related to build
system problems and is designed with extensibility in mind. While llbuild2 by itself is not a build system in itself,
you can build (hah) custom build systems with it.

### Functional build systems

Functional systems are caracterized by enforcing that the results (values) of evaluations (functions) are only affected
by the declared inputs (keys). Systems defined in such way can be smarter about the way evaluations are scheduled and
cached. Some of the benefits of functional systems include:

* If an evaluation is only affected by the input key, then the result can be memoized (cached) for future requests of
  the same key.
* If the value provided by an evaluation is not used as input to any other evaluation, then it can be skipped.
* If there are no dependencies between evaluations, they can be reordered and/or evaluated in parallel.

It is easy to see how this functional thinking maps into the actions executed as part of a build. If the outputs of an
action are only affected by the action's inputs (i.e. command-line arguments, environment variables, input artifacts),
then the build system can cache the results of that action for future requests of that same action.

This functional architecture can also be applied to the build graph itself, by considering the action graph as the value
of an evaluation where the key is the project sources plus the requested configuration. By modeling the different pieces
required to represent a build graph in their most granular versions, the construction of the action graph can also be
cached.

### Build phases

llbuild2 is architected around the 2 phases that happen in any build system implementation:

1. Evaluation: During this phase, project description files are parsed and evaluated in order to construct an action
   graph.
1. Execution: The action graph is evaluated in a way where only the actions affecting the requested outputs are
   executed. The ordering of these actions is implicit in the relationships between input and output artifacts.

### CAS usage

llbuild2 makes heavy use of CAS (Content Addressable Storage) technologies. With CAS, data, file and directory
structures can be represented and accessed by the digest (or hash) of its contents. Using CAS identifiers, llbuild2 can
detect when changes have ocurred to any portion of the build graph, and only reëvaluate the pieces that have never been
evaluated before.

With shared CAS services, it's even possible to reüse evaluation results across different development or CI machines.

### Remote execution

llbuild2 provides data structures that enforce that action specifications are completely defined. This allows clients of
llbuild2 to implement any kind of execution engine to power the action graph resolution. Through these interfaces, it
would be possible to support common remote execution APIs such as Bazel's RE2 protocol.
