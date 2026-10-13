#ifndef SHIROHA_EXTERNAL_NATIVE_H_
#define SHIROHA_EXTERNAL_NATIVE_H_

#include <stdint.h>

#if defined(SHIROHA_EXTERNAL_NATIVE_BUILD)
#define SHIROHA_NATIVE_API __declspec(dllexport)
#else
#define SHIROHA_NATIVE_API __declspec(dllimport)
#endif
#define SHIROHA_NATIVE_CALL __cdecl

#ifdef __cplusplus
extern "C" {
#endif

#define SHIROHA_NATIVE_ABI_VERSION 2u
#define SHIROHA_NATIVE_MAX_BYTES 65536u

// Fixed status categories only; statuses carry no OS error, path or secret.
enum ShirohaNativeStatus {
  SHIROHA_NATIVE_OK = 0,
  SHIROHA_NATIVE_INVALID_INPUT = 1,
  SHIROHA_NATIVE_ABI_MISMATCH = 2,
  SHIROHA_NATIVE_RESOURCE_LIMIT = 3,
  SHIROHA_NATIVE_UNAVAILABLE = 4,
  SHIROHA_NATIVE_DATA_CORRUPT = 5
};

enum ShirohaNativeOwner { SHIROHA_NATIVE_APP = 1, SHIROHA_NATIVE_BRIDGE = 2 };

// ABI 2 only. No caller paths/HANDLEs. token is aligned, live uint64_t storage.
// Success transfers a process-local owner token (never reused); failure sets 0.
// The owner holds verified parent/child handles + a no-sharing OS lock until
// close. validate never reacquires or revives a denied/closed owner. Native
// duplicate/unknown close is INVALID_INPUT. Failed OS close quarantines the
// slot, permanently denies the token and never retries a stale HANDLE value.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_acquire(
    uint32_t abi_version, uint32_t role, uint64_t* token);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_validate(
    uint32_t abi_version, uint64_t token);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_close(
    uint32_t abi_version, uint64_t token);

SHIROHA_NATIVE_API uint32_t SHIROHA_NATIVE_CALL shiroha_native_abi_version(void);

// Helper allocates zero-initialized, 8-byte-aligned storage (1..MAX_BYTES).
// Null means invalid size or allocation failure. The caller owns a live buffer
// until exactly one buffer_free of the original pointer, from this same DLL.
// No foreign/interior/already-freed pointer is permitted. Free wipes the entire
// allocation using its allocator-owned size; no caller-supplied wipe length.
SHIROHA_NATIVE_API uint8_t* SHIROHA_NATIVE_CALL shiroha_native_buffer_alloc(
    uint64_t capacity);
SHIROHA_NATIVE_API void SHIROHA_NATIVE_CALL shiroha_native_buffer_free(
    uint8_t* buffer);

// All pointers are borrowed, valid for the call; output, input and written must
// be disjoint live storage of the stated extent. written points to an aligned
// uint64_t. Caller allocates/frees all three; the helper owns/cleans API results.
// Output capacity is 1..MAX_BYTES; input length is 1..MAX_BYTES. Zero/oversize,
// null, overlapping spans and incompatible versions fail before any OS call.
// Valid disjoint output/count storage is cleared before work, including failure.
// Invalid aliases/addresses are not usable results and may remain untouched.
// No partial result is copied. Success writes exactly written initialized bytes.
// Known folder output is UTF-16LE without a terminator, not a protected root.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_local_app_data(
    uint32_t abi_version, uint8_t* output, uint64_t capacity, uint64_t* written);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_dpapi_protect(
    uint32_t abi_version, const uint8_t* input, uint64_t length,
    uint8_t* output, uint64_t capacity, uint64_t* written);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_dpapi_unprotect(
    uint32_t abi_version, const uint8_t* input, uint64_t length,
    uint8_t* output, uint64_t capacity, uint64_t* written);

#ifdef __cplusplus
}
#endif
#endif
