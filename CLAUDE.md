# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

llbuild2 is an experimental, Swift-native, fully async, NIO futures-based low-level build system framework. It is not a build system itself — it provides abstractions for building custom build systems with functional evaluation, CAS-backed caching, and remote execution support.

## Build Commands

```bash
swift build                          # Debug build
swift build -c release               # Release build
swift test                           # Run all tests
swift test --filter llbuild2fxTests  # Run specific test target
swift test --filter "EngineTests"    # Run a specific test class
swift test --filter "EngineTests/testBasicKey"  # Run a single test method
```

### Protobuf Regeneration

Generated protobuf sources are checked in. Regenerate only when proto definitions change:

```bash
make generate          # Regenerate all protobuf sources
make proto-toolchain   # Build protoc toolchain first if needed
make update            # Clone/update external proto repos (Bazel remote-apis, googleapis)
```

## Architecture

### Core Concepts

The framework implements a **functional build system**:
- **`FXKey`s** are computed locally to produce `FXValue`s. During evaluation, keys can request other keys and spawn actions through `FXFunctionInterface`, building up a dependency graph.
- **`FXAction`s** represent units of work that require a specific environment (e.g. a particular OS, toolchain, or sandbox) and/or are larger units of work. `FXExecutor` is responsible for distributing actions to the right environment(s), which are often provided by remote execution services.

### Key Protocols (all in `Sources/llbuild2fx/`)

- **`FXKey`** — A locally-computed unit. Implements `computeValue()` to produce an `FXValue`. Keys request other keys and spawn actions through `FXFunctionInterface`.
- **`FXValue`** — Result of key evaluation. Codable, with optional CAS data references (`refs: [LLBDataID]`).
- **`FXAction`** — A unit of work requiring a specific environment or representing larger tasks. Has requirements (worker size, network access) and version info.
- **`FXExecutor`** — Distributes actions to appropriate environments. Implementations: `FXLocalExecutor` (spawns processes locally), `FXNullExecutor` (testing).
- **`FXFunctionInterface`** — Interface available during key evaluation: `request()` other keys, `spawn()` actions, access `resource()`.
- **`FXRuleset`** / **`FXRulesetPackage`** — Groups related keys, actions, and resources. Defines entrypoints.
- **`FXService`** — Registry for rulesets and resources.
- **`FXResource`** — External dependencies (compilers, SDKs) with lifetime management and version tracking.
- **`FXFunctionCache`** — Caching interface. Implementations: `InMemoryFunctionCache`, `FileBackedFunctionCache` (in `ActionCache/`).
- **`FXVersioning`** — Version aggregation for cache key generation across dependency graphs.

### Module Structure

| Module | Purpose |
|---|---|
| `FXCore` | Public client-facing types: `LLBDataID`, `FXCASDatabase`, `FXCASObject`, NIO typealiases |
| `FXAsyncSupport` | Package-scoped internals: file trees, process executor, futures utilities, CAS implementations |
| `llbuild2fx` | Core engine: `FXEngine`, keys, actions, executors, caching, dependency graph. Re-exports `FXCore` |
| `llbuild2` | Convenience wrapper that reexports `llbuild2fx` |
| `llbuild2Testing` | Test utilities: `FXTestingEngine`, `FXLocalCASTreeService`, `FXKeyTestOverride` |
| `FXExampleRuleset` | Example ruleset for testing and reference (not part of the library) |

### Engine Flow

`FXEngine` (in `Engine.swift`) orchestrates everything:
1. A client requests evaluation of an `FXKey`
2. The engine checks `FXFunctionCache` for cached results
3. On cache miss, calls the key's `computeValue()` with an `FXFunctionInterface`
4. The key may `request()` other keys (creating dependencies tracked in `KeyDependencyGraph`) or `spawn()` actions
5. Results are stored in the cache and returned

### Async Model

Both NIO futures (`FXKey`) and Swift async/await (`AsyncFXKey`, `AsyncFXAction`) are supported.

## Code Style

Follow [Swift project guidelines for contributing code](https://swift.org/contributing/#contributing-code). All public types use the `FX` prefix.

### Error Handling

Prefer `throw` over `fatalError` wherever possible. If a function can throw, use a thrown error (e.g. an `FXError` case) instead of crashing the process. Reserve `fatalError` / `preconditionFailure` only for true programming errors that indicate a logic bug (e.g. unreachable code paths).

### Copyright Headers

New files use `// Copyright (c) <current_year> Apple Inc. and the Swift project authors`. When modifying an existing file, update its copyright to a year range ending at the current year (e.g. `// Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors`). The current year is 2026.
