#ifndef SHIROHA_EXTERNAL_NATIVE_CRYPTO_H_
#define SHIROHA_EXTERNAL_NATIVE_CRYPTO_H_

#include <cstddef>
#include <cstdint>

#include "shiroha_external_native.h"

namespace shiroha_native {
// Internal, non-exported seam. Offline tests link only this core with fake
// operations, never the production CNG wrapper or the production DLL. No
// operation may throw; every one returns a fixed status category.
struct CryptoOperations {
  // Writes a PKCS#8 DER private key (1..capacity bytes) and exactly 65 bytes
  // of uncompressed point into the caller-owned, zeroed buffers.
  int32_t (*generate)(uint8_t* pkcs8, size_t pkcs8_capacity,
                      size_t* pkcs8_length, uint8_t* point,
                      size_t point_capacity) noexcept;
  // Signs a 32-byte SHA-256 digest into exactly 64 bytes of raw r||s.
  int32_t (*sign)(const uint8_t* pkcs8, size_t pkcs8_length,
                  const uint8_t* point, const uint8_t* digest, uint8_t* raw) noexcept;
  // Verifies a 64-byte raw r||s over a 32-byte digest.
  int32_t (*verify)(const uint8_t* point, size_t point_length,
                    const uint8_t* digest, const uint8_t* raw) noexcept;
};

const CryptoOperations& windows_crypto_operations() noexcept;

int32_t generate_key(uint32_t version, uint8_t* pkcs8, uint64_t pkcs8_capacity,
                     uint64_t* pkcs8_written, uint8_t* point,
                     uint64_t point_capacity, uint64_t* point_written,
                     const CryptoOperations& ops) noexcept;
int32_t sign_digest(uint32_t version, const uint8_t* pkcs8,
                    uint64_t pkcs8_length, const uint8_t* point, uint64_t point_length,
                    const uint8_t* digest,
                    uint64_t digest_length, uint8_t* signature,
                    uint64_t signature_capacity, uint64_t* signature_written,
                    const CryptoOperations& ops) noexcept;
int32_t verify_digest(uint32_t version, const uint8_t* point,
                      uint64_t point_length, const uint8_t* digest,
                      uint64_t digest_length, const uint8_t* signature,
                      uint64_t signature_length,
                      const CryptoOperations& ops) noexcept;
}  // namespace shiroha_native
#endif
