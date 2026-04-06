// Wrapper that compiles the core BLAKE3 C sources.
// Platform-specific SIMD implementations are compiled separately.
#include "fx_blake3_prefix.h"

#if __x86_64__

#ifndef __SSE4_1__
#define BLAKE3_NO_SSE41
#endif
#ifndef __AVX2__
#define BLAKE3_NO_AVX2
#endif
#ifndef __AVX512__
#define BLAKE3_NO_AVX512
#endif

#include "impl/blake3.c"
#include "impl/blake3_dispatch.c"
#include "impl/blake3_portable.c"
#else
#include "impl/blake3.c"
#include "impl/blake3_dispatch.c"
#include "impl/blake3_portable.c"
#endif
