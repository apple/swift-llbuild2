# Overview

## What is llbuild2?

llbuild2 is an experimental, Swift-native, fully async build system framework. It is not a build system itself — it
provides abstractions for building custom build systems with functional evaluation, CAS-backed caching, and remote
execution support.

### Functional build systems

Functional systems are characterized by enforcing that the results (values) of evaluations (functions) are only affected
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

### Core abstractions

llbuild2 models builds through a small set of core abstractions (all using the `FX` prefix):

- **`FXKey`** — A locally-computed unit of evaluation. A key implements `computeValue()` to produce an `FXValue`.
  During evaluation, keys can request other keys and spawn actions through `FXFunctionInterface`, building up a
  dependency graph.
- **`FXValue`** — The result of evaluating a key. Values are `Codable` and `Sendable`, with optional CAS data
  references (`refs: [FXDataID]`).
- **`FXAction`** — A unit of work that may require a specific environment (e.g. a particular OS, toolchain, or
  sandbox). Actions have requirements (worker size, network access) and version info. An `FXExecutor` is responsible
  for distributing actions to appropriate environments.
- **`FXFunctionInterface`** — The interface available during key evaluation. Provides `request()` to depend on other
  keys, `spawn()` to run actions, and `resource()` to access external resources.
- **`FXRuleset`** / **`FXRulesetPackage`** — Groupings of related keys, actions, and resources that define
  entrypoints for a build system. `FXService` acts as a registry for rulesets and resources.
- **`FXVersioning`** — Version aggregation for cache key generation across dependency graphs, ensuring that changes
  to any key or action in a dependency chain correctly invalidate downstream caches.

### Engine flow

`FXEngine` orchestrates evaluation:

1. A client requests evaluation of an `FXKey` via `engine.build(key:)`.
2. The engine checks `FXFunctionCache` for a cached result.
3. On a cache miss, the engine calls the key's `computeValue()`, providing an `FXFunctionInterface`.
4. During computation, the key may `request()` other keys (creating dependencies tracked in `KeyDependencyGraph`) or
   `spawn()` actions (dispatched to the configured `FXExecutor`).
5. Results are stored in the CAS and the function cache, then returned.

Both NIO futures (`FXKey.computeValue() -> FXFuture`) and Swift async/await (`AsyncFXKey.computeValue() async throws`)
are supported.

### CAS usage

llbuild2 makes heavy use of CAS (Content Addressable Storage) technologies. With CAS, data, file, and directory
structures can be represented and accessed by the digest (or hash) of their contents. Using CAS identifiers (`FXDataID`,
computed via BLAKE3), llbuild2 can detect when changes have occurred to any portion of the build graph and only
reëvaluate the pieces that have never been evaluated before.

With shared CAS services, it's even possible to reuse evaluation results across different development or CI machines.

### Remote execution

llbuild2 provides data structures (`FXAction`, `FXActionRequirements`) that enforce that action specifications are
completely defined. This allows clients to implement any kind of `FXExecutor` to power action execution, including
remote execution backends. The built-in `FXLocalExecutor` spawns processes locally, and `FXNullExecutor` is available
for testing.

### Module structure

| Module | Purpose |
|---|---|
| `FXCore` | Public client-facing types: `FXDataID`, `FXCASDatabase`, `FXCASObject`, NIO typealiases |
| `FXAsyncSupport` | Package-scoped internals: file trees, process executor, futures utilities, CAS implementations |
| `llbuild2fx` | Core engine: `FXEngine`, keys, actions, executors, caching, dependency graph. Re-exports `FXCore` |
| `llbuild2` | Convenience wrapper that re-exports `llbuild2fx` |
| `llbuild2Testing` | Test utilities: `FXTestingEngine`, `FXLocalCASTreeService`, `FXKeyTestOverride` |
