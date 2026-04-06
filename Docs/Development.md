# Development

This document contains information on how to develop `llbuild2`.

## Building

```bash
swift build                          # Debug build
swift build -c release               # Release build
swift test                           # Run all tests
swift test --filter llbuild2fxTests  # Run specific test target
swift test --filter "EngineTests"    # Run a specific test class
swift test --filter "EngineTests/testBasicKey"  # Run a single test method
```

## Protobuf Regeneration

Generated protobuf sources are checked in. Regenerate only when proto definitions change:

```bash
make generate          # Regenerate all protobuf sources
make proto-toolchain   # Build protoc toolchain first if needed
make update            # Clone/update external proto repos
```

## Code Style

Follow [Swift project guidelines for contributing code](https://swift.org/contributing/#contributing-code). All public
types use the `FX` prefix.

New files use `// Copyright (c) <current_year> Apple Inc. and the Swift project authors`. When modifying an existing
file, update its copyright to a year range ending at the current year.

### Error Handling

Prefer `throw` over `fatalError` wherever possible. If a function can throw, use a thrown error (e.g. an `FXError`
case) instead of crashing the process. Reserve `fatalError` / `preconditionFailure` only for true programming errors
that indicate a logic bug (e.g. unreachable code paths).
