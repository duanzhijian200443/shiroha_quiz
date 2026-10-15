#include "native_crypto.h"
#include "p256_key_codec.h"

#include <windows.h>

#include <bcrypt.h>

#include <cstring>

// Real CNG implementation. It is linked only into the production DLL; the
// G0-L0 offline tests never load or call it, so no real key, signature or
// G0-L1 security object is ever produced by this slice. Every handle is
// released through RAII and no path lets an exception or C++ object cross the
// C ABI.
namespace {
constexpr size_t kPkcs8Capacity = SHIROHA_NATIVE_ECDSA_PKCS8_MAX;
constexpr size_t kPointBytes = SHIROHA_NATIVE_ECDSA_POINT_BYTES;
constexpr size_t kCoordinateBytes = 32;
constexpr size_t kDigestBytes = SHIROHA_NATIVE_ECDSA_DIGEST_BYTES;
constexpr size_t kRawBytes = SHIROHA_NATIVE_ECDSA_RAW_BYTES;
constexpr size_t kPublicBlobBytes =
    sizeof(BCRYPT_ECCKEY_BLOB) + 2 * kCoordinateBytes;

// ntstatus.h cannot be included next to winnt.h without WIN32_NO_STATUS, and
// this translation unit needs exactly one documented NTSTATUS value:
// STATUS_INVALID_SIGNATURE (0xC000A000).
constexpr NTSTATUS kStatusInvalidSignature = static_cast<NTSTATUS>(0xC000A000L);

struct AlgorithmProvider {
  BCRYPT_ALG_HANDLE handle = nullptr;
  AlgorithmProvider() noexcept {
    // Frozen candidate: BCRYPT_ECDSA_P256_ALGORITHM + SHA-256, no third-party
    // crypto dependency.
    if (BCryptOpenAlgorithmProvider(&handle, BCRYPT_ECDSA_P256_ALGORITHM,
                                    MS_PRIMITIVE_PROVIDER, 0) < 0) {
      handle = nullptr;
    }
  }
  ~AlgorithmProvider() noexcept {
    if (handle) BCryptCloseAlgorithmProvider(handle, 0);
  }
  AlgorithmProvider(const AlgorithmProvider&) = delete;
  AlgorithmProvider& operator=(const AlgorithmProvider&) = delete;
  bool valid() const noexcept { return handle != nullptr; }
};

struct KeyHandle {
  BCRYPT_KEY_HANDLE handle = nullptr;
  KeyHandle() noexcept = default;
  ~KeyHandle() noexcept {
    if (handle) BCryptDestroyKey(handle);
  }
  KeyHandle(const KeyHandle&) = delete;
  KeyHandle& operator=(const KeyHandle&) = delete;
};

int32_t generate(uint8_t* pkcs8, size_t pkcs8_capacity, size_t* pkcs8_length,
                 uint8_t* point, size_t point_capacity) noexcept {
  if (pkcs8_capacity < 1 || pkcs8_capacity > kPkcs8Capacity ||
      point_capacity < kPointBytes) {
    return SHIROHA_NATIVE_RESOURCE_LIMIT;
  }
  AlgorithmProvider provider;
  if (!provider.valid()) return SHIROHA_NATIVE_UNAVAILABLE;
  KeyHandle key;
  if (BCryptGenerateKeyPair(provider.handle, &key.handle, 256, 0) < 0) {
    return SHIROHA_NATIVE_UNAVAILABLE;
  }
  if (BCryptFinalizeKeyPair(key.handle, 0) < 0) {
    return SHIROHA_NATIVE_UNAVAILABLE;
  }
  struct PrivateBlob {
    BCRYPT_ECCKEY_BLOB header{};
    uint8_t coordinates_and_scalar[96]{};
    ~PrivateBlob() noexcept { SecureZeroMemory(this, sizeof(*this)); }
  } blob;
  static_assert(sizeof(PrivateBlob) == 104, "CNG ECC blob layout");
  ULONG blob_size = 0;
  if (BCryptExportKey(key.handle, nullptr, BCRYPT_ECCPRIVATE_BLOB,
      reinterpret_cast<PUCHAR>(&blob), sizeof(blob), &blob_size, 0) < 0 ||
      blob_size != sizeof(blob) || blob.header.dwMagic != BCRYPT_ECDSA_PRIVATE_P256_MAGIC ||
      blob.header.cbKey != 32) return SHIROHA_NATIVE_DATA_CORRUPT;
  point[0] = 4;
  std::memcpy(point+1, blob.coordinates_and_scalar, 64);
  size_t written = 0;
  if (!shiroha_native::encode_p256_pkcs8(blob.coordinates_and_scalar+64,
      point, pkcs8, pkcs8_capacity, &written)) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  *pkcs8_length = written;
  return SHIROHA_NATIVE_OK;
}

int32_t sign(const uint8_t* pkcs8, size_t pkcs8_length, const uint8_t* point, const uint8_t* digest,
             uint8_t* raw) noexcept {
  AlgorithmProvider provider;
  if (!provider.valid()) return SHIROHA_NATIVE_UNAVAILABLE;
  struct PrivateBlob {
    BCRYPT_ECCKEY_BLOB header{BCRYPT_ECDSA_PRIVATE_P256_MAGIC,32};
    uint8_t coordinates_and_scalar[96]{};
    ~PrivateBlob() noexcept { SecureZeroMemory(this, sizeof(*this)); }
  } blob;
  if (!shiroha_native::decode_p256_pkcs8(pkcs8,pkcs8_length,point,
      blob.coordinates_and_scalar+64)) return SHIROHA_NATIVE_DATA_CORRUPT;
  std::memcpy(blob.coordinates_and_scalar,point+1,64);
  KeyHandle key;
  if (BCryptImportKeyPair(provider.handle, nullptr, BCRYPT_ECCPRIVATE_BLOB,
      &key.handle, reinterpret_cast<PUCHAR>(&blob), sizeof(blob), 0) < 0)
    return SHIROHA_NATIVE_DATA_CORRUPT;
  ULONG written = 0;
  if (BCryptSignHash(key.handle, nullptr, const_cast<PUCHAR>(digest),
                     static_cast<ULONG>(kDigestBytes), raw,
                     static_cast<ULONG>(kRawBytes), &written, 0) < 0) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  // CNG ECDSA output is exactly 64 bytes of raw r||s. The DER
  // ECDSA-Sig-Value used by X.509 is a separate certificate-encoder step.
  return written == kRawBytes ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_DATA_CORRUPT;
}

int32_t verify(const uint8_t* point, size_t point_length,
               const uint8_t* digest, const uint8_t* raw) noexcept {
  if (point_length != kPointBytes || point[0] != 0x04) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  AlgorithmProvider provider;
  if (!provider.valid()) return SHIROHA_NATIVE_UNAVAILABLE;
  uint8_t blob[kPublicBlobBytes] = {};
  auto* header = reinterpret_cast<BCRYPT_ECCKEY_BLOB*>(blob);
  header->dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
  header->cbKey = static_cast<ULONG>(kCoordinateBytes);
  std::memcpy(blob + sizeof(BCRYPT_ECCKEY_BLOB), point + 1,
              2 * kCoordinateBytes);
  KeyHandle key;
  if (BCryptImportKeyPair(provider.handle, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                          &key.handle, blob, static_cast<ULONG>(sizeof(blob)),
                          0) < 0) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  const NTSTATUS status = BCryptVerifySignature(
      key.handle, nullptr, const_cast<PUCHAR>(digest),
      static_cast<ULONG>(kDigestBytes), const_cast<PUCHAR>(raw),
      static_cast<ULONG>(kRawBytes), 0);
  if (status >= 0) return SHIROHA_NATIVE_OK;
  // Only an explicit signature mismatch is verificationRejected; every other
  // failure (bad key, unsupported blob, provider error) stays dataCorrupt.
  return status == kStatusInvalidSignature
             ? SHIROHA_NATIVE_VERIFICATION_REJECTED
             : SHIROHA_NATIVE_DATA_CORRUPT;
}

const shiroha_native::CryptoOperations operations{generate, sign, verify};
}  // namespace

namespace shiroha_native {
const CryptoOperations& windows_crypto_operations() noexcept {
  return operations;
}
}  // namespace shiroha_native

int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_generate_key(
    uint32_t version, uint8_t* private_key, uint64_t private_capacity,
    uint64_t* private_written, uint8_t* public_key, uint64_t public_capacity,
    uint64_t* public_written) {
  return shiroha_native::generate_key(version, private_key, private_capacity,
                                      private_written, public_key,
                                      public_capacity, public_written,
                                      operations);
}

int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_sign_digest(
    uint32_t version, const uint8_t* private_key, uint64_t private_length,
    const uint8_t* public_key, uint64_t public_length, const uint8_t* digest, uint64_t digest_length, uint8_t* signature,
    uint64_t signature_capacity, uint64_t* signature_written) {
  return shiroha_native::sign_digest(version, private_key, private_length, public_key, public_length,
                                     digest, digest_length, signature,
                                     signature_capacity, signature_written,
                                     operations);
}

int32_t SHIROHA_NATIVE_CALL shiroha_native_ecdsa_verify_digest(
    uint32_t version, const uint8_t* public_key, uint64_t public_length,
    const uint8_t* digest, uint64_t digest_length, const uint8_t* signature,
    uint64_t signature_length) {
  return shiroha_native::verify_digest(version, public_key, public_length,
                                       digest, digest_length, signature,
                                       signature_length, operations);
}
