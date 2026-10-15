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

#define SHIROHA_NATIVE_ABI_VERSION 3u
#define SHIROHA_NATIVE_MAX_BYTES 65536u

// Fixed status categories only; statuses carry no OS error, path or secret.
enum ShirohaNativeStatus {
  SHIROHA_NATIVE_OK = 0,
  SHIROHA_NATIVE_INVALID_INPUT = 1,
  SHIROHA_NATIVE_ABI_MISMATCH = 2,
  SHIROHA_NATIVE_RESOURCE_LIMIT = 3,
  SHIROHA_NATIVE_UNAVAILABLE = 4,
  SHIROHA_NATIVE_DATA_CORRUPT = 5,
  SHIROHA_NATIVE_MISSING = 6,
  SHIROHA_NATIVE_COMMIT_UNKNOWN = 7,
  // ABI-3 additive: returned only by the ECDSA verification export below when a
  // well-formed key/digest/signature triple does not verify. It never replaces
  // or renumbers an existing status, and pre-P21 callers never observe it.
  SHIROHA_NATIVE_VERIFICATION_REJECTED = 8
};

enum ShirohaNativeOwner { SHIROHA_NATIVE_APP = 1, SHIROHA_NATIVE_BRIDGE = 2 };

// ABI-3 additive ECDSA P-256 / SHA-256 primitives (frozen P16 section 9.A.2). They
// accept ABI 3 only, never 1/2, and add no new ABI number: the twelve P18-P20
// exports keep byte-identical signatures and semantics, so an existing ABI-3
// caller is unaffected. A caller that needs these symbols must load them
// explicitly; absence means an older helper, never a downgraded operation.
// All spans are borrowed, live, disjoint storage of the stated extent; output
// and disjoint count storage is cleared before work and on failure; aliased /
// invalid spans are unusable and remain untouched. Private-key /
// signature buffers are wiped on every failure path. No C++ object, container
// or exception crosses this boundary. Callers must dispose of their own copies.
#define SHIROHA_NATIVE_ECDSA_PKCS8_MAX 256u
#define SHIROHA_NATIVE_ECDSA_POINT_BYTES 65u
#define SHIROHA_NATIVE_ECDSA_DIGEST_BYTES 32u
#define SHIROHA_NATIVE_ECDSA_RAW_BYTES 64u

// Generates a fresh P-256 key pair. Writes PKCS#8 DER (1..256 bytes) and the
// 65-byte uncompressed point (0x04 || X || Y). Real CNG key generation is a
// G0-L1 operation; this export is never invoked by G0-L0 tests.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_generate_key(
    uint32_t version, uint8_t* private_key, uint64_t private_capacity,
    uint64_t* private_written, uint8_t* public_key, uint64_t public_capacity,
    uint64_t* public_written);

// Public point is explicit (65 bytes), including for PKCS#8 without a SEC1
// publicKey. CNG validates the full private/public pair. Signature capacity=64;
// generated public capacity=65; private capacity is bounded at 256.
// Signs one 32-byte SHA-256 digest and writes the fixed 64-byte raw r||s.
// The DER ECDSA-Sig-Value form used by X.509 is a separate conversion owned by
// the certificate encoder; this export never emits DER.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_sign_digest(
    uint32_t version, const uint8_t* private_key, uint64_t private_length,
    const uint8_t* public_key, uint64_t public_length,
    const uint8_t* digest, uint64_t digest_length, uint8_t* signature,
    uint64_t signature_capacity, uint64_t* signature_written);

// Verifies one 64-byte raw r||s over a 32-byte SHA-256 digest. OK means the
// signature verified; VERIFICATION_REJECTED means it did not; malformed input,
// wrong curve or wrong size is INVALID_INPUT / DATA_CORRUPT and never OK.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_verify_digest(
    uint32_t version, const uint8_t* public_key, uint64_t public_length,
    const uint8_t* digest, uint64_t digest_length, const uint8_t* signature,
    uint64_t signature_length);

// Owner calls accept ABI 2/3. No caller paths/HANDLEs. token is aligned, live uint64_t storage.
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

// ABI 3: fixed App associations.bin only. Begin retains one transaction per
// owner; OK or MISSING transfers a positive ticket, even for an empty snapshot.
// Caller frees output with buffer_free, and settles ticket with commit or abort.
// No plaintext enters these file calls. All spans/count/ticket must be disjoint.
// commit consumes the ticket on every outcome, never retries an uncertain rename.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_association_begin(
    uint32_t version, uint64_t owner, uint8_t* output, uint64_t capacity,
    uint64_t* written, uint64_t* ticket);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_association_commit(
    uint32_t version, uint64_t owner, uint64_t ticket,
    const uint8_t* input, uint64_t length);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_association_abort(
    uint32_t version, uint64_t owner, uint64_t ticket);

// ABI-3 optional additive capability: fixed kinds 1/2 App, 4 Bridge only.
// Same borrowed-span, zero-on-failure, one-ticket and bounded ciphertext rules
// as association calls. The owner shares ONE transaction across all its kinds.
// Commit/abort accept only tickets issued by credential_begin. No paths/HANDLEs.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_begin(
    uint32_t version, uint64_t owner, uint32_t kind, uint8_t* output,
    uint64_t capacity, uint64_t* written, uint64_t* ticket);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_commit(
    uint32_t version, uint64_t owner, uint64_t ticket, const uint8_t* input, uint64_t length);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_abort(
    uint32_t version, uint64_t owner, uint64_t ticket);

// Optional ABI-3 P24 capability. Kind 1=submission (Bridge writes/App reads),
// 2=challenge (App writes/Bridge reads), 3=proof (Bridge writes/App reads).
// id is exactly 16 borrowed bytes; native constructs the ONLY legal basename.
// All spans/counts are live and disjoint; valid outputs clear on failure.
// Caps: 1024/4096/256. No P22 parsing/authorization is implied by raw I/O.
// Create-new never overwrites. Success returns a process-local, owner-bound
// creator receipt with a retained identity pin (32 max). No read/delete-on-read.
// Cleanup consumes one creator receipt on every result, reopens the exact name
// under the verified directory and deletes by verified handle only on identity
// match. Owner close drops pins WITHOUT deleting files. No retry or sweep.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_create(
    uint32_t version, uint64_t owner, uint32_t kind, const uint8_t* id,
    const uint8_t* input, uint64_t length, uint64_t* receipt);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_read(
    uint32_t version, uint64_t owner, uint32_t kind, const uint8_t* id,
    uint8_t* output, uint64_t capacity, uint64_t* written);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_cleanup(
    uint32_t version, uint64_t owner, uint64_t receipt);

// Optional ABI-3 E0. Ticket is 24 borrowed bytes, aligned to 8: an opaque
// never-reused serial plus 128 random bits. No caller-selected deletion target.
// ReadBegin outputs (id/output/written/ticket) are disjoint; valid outputs clear
// on failure. Caps/roles match Read. At most 32 reader pins per owner.
// Consume/Release retire a matching owner-bound ticket BEFORE any attempt.
// Consume revalidates identity/security and exact original bytes on a fresh
// protected read+delete handle, then requests deletion through THAT handle.
// Success means the handle deletion operation and releases succeeded, not crash
// durability, Pairing evidence or approval. Unknown deletion is never retried.
// Release and OwnerClose only release pins, never delete.
#define SHIROHA_NATIVE_EXCHANGE_TICKET_BYTES 24u
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_read_begin(
    uint32_t version, uint64_t owner, uint32_t kind, const uint8_t* id,
    uint8_t* output, uint64_t capacity, uint64_t* written, uint8_t* ticket);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_consume(
    uint32_t version, uint64_t owner, const uint8_t* ticket);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_release(
    uint32_t version, uint64_t owner, const uint8_t* ticket);

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

// P26 optional ABI-3 fixed Discovery capability: 1 endpoint.bin (185),
// 2 anchor.der (1..1024), 3 installation.id (36). Publish is App-only.
// Read capacity must equal the fixed cap. Missing clears output/count.
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_discovery_publish(
    uint32_t abi_version, uint64_t owner, uint32_t kind, const uint8_t* input, uint64_t length);
SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL shiroha_native_discovery_read(
    uint32_t abi_version, uint64_t owner, uint32_t kind, uint8_t* output, uint64_t capacity, uint64_t* written);
#ifdef __cplusplus
}
#endif
#endif
