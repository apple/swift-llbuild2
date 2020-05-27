# Serialization

llbuild2 makes heavy use of serialization for storing keys and values in the CAS. For this purpose, we're making use of 
SwiftProtobuf for a couple of reasons:

1. Data structure definitions are defined externally to the code. This makes it easier to navigate the codebase understanding
the basic building blocks for the build system, leaving Swift code to only encode the logic en how the data structures are processed.
1. Support for polymorphic codables through `google.protobuf.Any`. llbuild2 is designed around extensibility, so there are places where we'd like to encode client data without knowing what the types are, but with the flexibility to access runtime information for inspection, which is available through `SwiftProtobuf.Google_Protobuf_Any`'s static type registry.

There are downsides to using protocol buffers though, such as:

* The protocol buffers specification requires that fields have default values, which doesn't play well with Swift Optional support. For message types, the fields will generate some `hasX` properties that can be used for this purpose.
