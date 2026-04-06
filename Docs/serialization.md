# Serialization

llbuild2 uses multiple serialization strategies depending on the context:

## Value Serialization

`FXValue` types are serialized for storage in the CAS using the `Codable` protocol. Each value provides:

- **`codableValue`** — The `Codable` representation of the value's data.
- **`refs`** — An array of `FXDataID` references to other CAS objects.

These are combined into an `FXCASObject` (data + refs) for storage. For types that directly conform to `Codable`,
default implementations are provided — `codableValue` returns `self` and `refs` returns an empty array.

Collection types (`Array`, `FXSortedSet`, `Optional`) have built-in `FXValue` conformances that correctly distribute
refs across elements.

## Key Serialization

`FXKey` types must conform to `Encodable` for cache key generation. The engine encodes keys using:

1. **`CommandLineArgsEncoder`** — For short keys (under 250 characters), produces a space-separated args representation.
2. **`FXEncoder` (JSON)** — For medium keys, produces a JSON encoding.
3. **BLAKE3 hash** — For long keys, the JSON encoding is hashed to produce a compact identifier. An optional `hint`
   property on the key can provide a human-readable prefix.

## Protobuf

Protocol Buffers are used for a small number of foundational types where cross-language compatibility or wire format
stability is important:

- `FXDataID` — CAS data identifier (defined in `data_id.proto`).
- `FXPBCASObject` — CAS object wire format (defined in `cas_object.proto`).
- `AnySerializable` — Polymorphic serialization wrapper (defined in `any_serializable.proto`).

Generated Swift sources are checked into the repository and should be regenerated with `make generate` when proto
definitions change.

## Internal Metadata

When values are stored in the cache, the engine wraps them in an `InternalValue` that includes metadata such as
`requestedCacheKeyPaths` (tracking which other keys were requested during evaluation) and a `creationDate` timestamp.
This metadata is transparent to key implementations.
