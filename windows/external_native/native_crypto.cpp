#include "native_crypto.h"

#include <windows.h>

#include <cstring>
#include <limits>

namespace {
constexpr uint64_t kMaxPkcs8 = SHIROHA_NATIVE_ECDSA_PKCS8_MAX;
constexpr uint64_t kPointBytes = SHIROHA_NATIVE_ECDSA_POINT_BYTES;
constexpr uint64_t kDigestBytes = SHIROHA_NATIVE_ECDSA_DIGEST_BYTES;
constexpr uint64_t kRawBytes = SHIROHA_NATIVE_ECDSA_RAW_BYTES;

bool span(const void* pointer, uint64_t length) noexcept {
  if (!pointer || length == 0 || length > SHIROHA_NATIVE_MAX_BYTES) return false;
  const auto start = reinterpret_cast<uintptr_t>(pointer);
  return start <= (std::numeric_limits<uintptr_t>::max)() - length;
}

bool aligned(const void* pointer) noexcept {
  return reinterpret_cast<uintptr_t>(pointer) % alignof(uint64_t) == 0;
}

bool overlaps(const void* a, uint64_t a_size, const void* b,
              uint64_t b_size) noexcept {
  const auto x = reinterpret_cast<uintptr_t>(a);
  const auto y = reinterpret_cast<uintptr_t>(b);
  return x < y + b_size && y < x + a_size;
}

void clear(void* buffer, uint64_t length) noexcept {
  SecureZeroMemory(buffer, static_cast<SIZE_T>(length));
}

// The count output is the only storage that may still be written after a
// failure; an invalid count address must never be touched.
bool validCount(uint64_t* written) noexcept {
  return span(written, sizeof(*written)) && aligned(written);
}
}  // namespace

namespace shiroha_native {
int32_t generate_key(uint32_t version, uint8_t* pkcs8, uint64_t pkcs8_capacity,
                     uint64_t* pkcs8_written, uint8_t* point,
                     uint64_t point_capacity, uint64_t* point_written,
                     const CryptoOperations& ops) noexcept {
  const bool key_valid =
      span(pkcs8, pkcs8_capacity) && pkcs8_capacity <= kMaxPkcs8;
  const bool point_valid =
      span(point, point_capacity) && point_capacity == kPointBytes;
  const bool key_count = validCount(pkcs8_written);
  const bool point_count = validCount(point_written);
  const bool key_count_alias = key_count &&
    ((span(pkcs8,pkcs8_capacity) && overlaps(pkcs8_written,8,pkcs8,pkcs8_capacity)) ||
     (span(point,point_capacity) && overlaps(pkcs8_written,8,point,point_capacity)) ||
     (point_count && overlaps(pkcs8_written,8,point_written,8)));
  const bool point_count_alias = point_count &&
    ((span(pkcs8,pkcs8_capacity) && overlaps(point_written,8,pkcs8,pkcs8_capacity)) ||
     (span(point,point_capacity) && overlaps(point_written,8,point,point_capacity)) ||
     (key_count && overlaps(point_written,8,pkcs8_written,8)));
  const bool outputs_alias = key_valid && point_valid &&
    overlaps(pkcs8,pkcs8_capacity,point,point_capacity);
  if (key_count && !key_count_alias) *pkcs8_written = 0;
  if (point_count && !point_count_alias) *point_written = 0;
  if (key_valid && !outputs_alias && !key_count_alias && !point_count_alias)
    clear(pkcs8,pkcs8_capacity);
  if (point_valid && !outputs_alias && !key_count_alias && !point_count_alias)
    clear(point,point_capacity);
  if (!key_valid || !point_valid || !key_count || !point_count ||
      key_count_alias || point_count_alias || outputs_alias) return SHIROHA_NATIVE_INVALID_INPUT;
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  clear(pkcs8, pkcs8_capacity);
  clear(point, point_capacity);
  size_t length = 0;
  const auto status = ops.generate(pkcs8, static_cast<size_t>(pkcs8_capacity),
                                   &length, point,
                                   static_cast<size_t>(point_capacity));
  if (status != SHIROHA_NATIVE_OK || length == 0 ||
      length > pkcs8_capacity) {
    // Private-key material never leaves a partial result on a failure path.
    clear(pkcs8, pkcs8_capacity);
    clear(point, point_capacity);
    return status == SHIROHA_NATIVE_OK ? SHIROHA_NATIVE_DATA_CORRUPT : status;
  }
  *pkcs8_written = length;
  *point_written = kPointBytes;
  return SHIROHA_NATIVE_OK;
}

int32_t sign_digest(uint32_t version, const uint8_t* pkcs8,
                    uint64_t pkcs8_length, const uint8_t* point, uint64_t point_length,
                    const uint8_t* digest,
                    uint64_t digest_length, uint8_t* signature,
                    uint64_t signature_capacity, uint64_t* signature_written,
                    const CryptoOperations& ops) noexcept {
  const bool key_valid = span(pkcs8, pkcs8_length) && pkcs8_length <= kMaxPkcs8;
  const bool digest_valid =
      span(digest, digest_length) && digest_length == kDigestBytes;
  const bool output_valid =
      span(signature, signature_capacity) && signature_capacity == kRawBytes;
  const bool count_valid = validCount(signature_written);
  const bool point_valid = span(point,point_length) && point_length==kPointBytes;
  const auto aliases = [](const void* a,uint64_t n,const void* b,uint64_t m) noexcept {
    return span(a,n) && span(b,m) && overlaps(a,n,b,m);
  };
  const bool count_alias = count_valid &&
    (aliases(signature_written,8,pkcs8,pkcs8_length) ||
     aliases(signature_written,8,point,point_length) ||
     aliases(signature_written,8,digest,digest_length) ||
     aliases(signature_written,8,signature,signature_capacity));
  const bool output_alias = aliases(signature,signature_capacity,pkcs8,pkcs8_length) ||
    aliases(signature,signature_capacity,point,point_length) ||
    aliases(signature,signature_capacity,digest,digest_length) || count_alias;
  if (count_valid && !count_alias) *signature_written=0;
  if (output_valid && !output_alias) clear(signature,signature_capacity);
  if (!key_valid || !point_valid || !digest_valid || !output_valid || !count_valid ||
      count_alias || output_alias || aliases(pkcs8,pkcs8_length,point,point_length) ||
      aliases(pkcs8,pkcs8_length,digest,digest_length) ||
      aliases(point,point_length,digest,digest_length)) return SHIROHA_NATIVE_INVALID_INPUT;
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  const auto status =
      ops.sign(pkcs8, static_cast<size_t>(pkcs8_length), point, digest, signature);
  if (status != SHIROHA_NATIVE_OK) {
    clear(signature, signature_capacity);
    return status;
  }
  *signature_written = kRawBytes;
  return SHIROHA_NATIVE_OK;
}

int32_t verify_digest(uint32_t version, const uint8_t* point,
                      uint64_t point_length, const uint8_t* digest,
                      uint64_t digest_length, const uint8_t* signature,
                      uint64_t signature_length,
                      const CryptoOperations& ops) noexcept {
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!span(point, point_length) || point_length != kPointBytes ||
      !span(digest, digest_length) || digest_length != kDigestBytes ||
      !span(signature, signature_length) || signature_length != kRawBytes) {
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  if (overlaps(point, point_length, digest, digest_length) ||
      overlaps(point, point_length, signature, signature_length) ||
      overlaps(digest, digest_length, signature, signature_length)) {
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  const auto status = ops.verify(point, static_cast<size_t>(point_length),
                                 digest, signature);
  switch (status) {
    case SHIROHA_NATIVE_OK:
    case SHIROHA_NATIVE_VERIFICATION_REJECTED:
    case SHIROHA_NATIVE_DATA_CORRUPT:
    case SHIROHA_NATIVE_UNAVAILABLE:
      return status;
    default:
      return SHIROHA_NATIVE_DATA_CORRUPT;
  }
}
}  // namespace shiroha_native
