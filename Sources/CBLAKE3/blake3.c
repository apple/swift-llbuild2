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

#include "../../ThirdParty/BLAKE3/c/blake3.c"
#include "../../ThirdParty/BLAKE3/c/blake3_dispatch.c"
#include "../../ThirdParty/BLAKE3/c/blake3_portable.c"
#else
#include "../../ThirdParty/BLAKE3/c/blake3.c"
#include "../../ThirdParty/BLAKE3/c/blake3_dispatch.c"
#include "../../ThirdParty/BLAKE3/c/blake3_portable.c"
#endif
