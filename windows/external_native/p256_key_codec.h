#ifndef SHIROHA_P256_KEY_CODEC_H_
#define SHIROHA_P256_KEY_CODEC_H_
#include <cstddef>
#include <cstdint>

namespace shiroha_native {
// Pure RFC 5208 / RFC 5915 conversion. No OS calls and no allocation.
// The caller supplies disjoint live spans and wipes private scalar storage.
bool encode_p256_pkcs8(const uint8_t* scalar, const uint8_t* point,
                       uint8_t* output, size_t capacity,
                       size_t* written) noexcept;
// Optional SEC1 parameters/publicKey are checked when present. A missing
// publicKey uses the explicit caller point; CNG validates the full key pair.
bool decode_p256_pkcs8(const uint8_t* input, size_t length,
                       const uint8_t* point, uint8_t* scalar) noexcept;
bool p256_scalar_valid(const uint8_t* scalar) noexcept;
}
#endif
