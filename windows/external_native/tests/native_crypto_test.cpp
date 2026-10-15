#include "native_crypto.h"
#include "p256_key_codec.h"

#include <cstdlib>
#include <cstring>
#include <iostream>

// Fake-only offline contract test. This executable links only
// native_crypto.cpp plus the fake operations below. It never loads the
// production DLL, never calls a real CNG or certificate API and produces no
// key or signature. All bytes are synthetic fixtures.
namespace {
constexpr uint8_t kFill = 0xAA;
uint8_t pkcs8_fixture[67] = {};
uint8_t point_fixture[SHIROHA_NATIVE_ECDSA_POINT_BYTES] = {};
uint8_t digest_fixture[SHIROHA_NATIVE_ECDSA_DIGEST_BYTES] = {};
uint8_t raw_fixture[SHIROHA_NATIVE_ECDSA_RAW_BYTES] = {};

int generate_calls = 0, sign_calls = 0, verify_calls = 0;
int32_t generate_status = SHIROHA_NATIVE_OK;
int32_t sign_status = SHIROHA_NATIVE_OK;
int32_t verify_status = SHIROHA_NATIVE_OK;
size_t generate_length = sizeof(pkcs8_fixture);

void check(bool ok, const char* label) {
  if (!ok) {
    std::cerr << "FAIL: offline crypto contract: " << label << "\n";
    std::exit(1);
  }
}

bool allBytes(const void* buffer, size_t length, uint8_t value) {
  const auto* bytes = static_cast<const uint8_t*>(buffer);
  for (size_t i = 0; i < length; ++i) {
    if (bytes[i] != value) return false;
  }
  return true;
}

int32_t fake_generate(uint8_t* pkcs8, size_t capacity, size_t* length,
                      uint8_t* point, size_t point_capacity) noexcept {
  ++generate_calls;
  if (point_capacity < SHIROHA_NATIVE_ECDSA_POINT_BYTES) {
    return SHIROHA_NATIVE_RESOURCE_LIMIT;
  }
  if (generate_status != SHIROHA_NATIVE_OK) return generate_status;
  if (generate_length > capacity) return SHIROHA_NATIVE_OK;
  std::memcpy(pkcs8, pkcs8_fixture, generate_length);
  *length = generate_length;
  std::memcpy(point, point_fixture, SHIROHA_NATIVE_ECDSA_POINT_BYTES);
  return SHIROHA_NATIVE_OK;
}

int32_t fake_sign(const uint8_t* pkcs8, size_t pkcs8_length,
                  const uint8_t* point, const uint8_t* digest, uint8_t* raw) noexcept {
  ++sign_calls;
  if (std::memcmp(point, point_fixture, sizeof(point_fixture)) != 0) return SHIROHA_NATIVE_DATA_CORRUPT;
  if (sign_status != SHIROHA_NATIVE_OK) return sign_status;
  if (pkcs8_length != sizeof(pkcs8_fixture) ||
      std::memcmp(pkcs8, pkcs8_fixture, sizeof(pkcs8_fixture)) != 0 ||
      std::memcmp(digest, digest_fixture, sizeof(digest_fixture)) != 0) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  std::memcpy(raw, raw_fixture, sizeof(raw_fixture));
  return SHIROHA_NATIVE_OK;
}

int32_t fake_verify(const uint8_t* point, size_t point_length,
                    const uint8_t* digest, const uint8_t* raw) noexcept {
  ++verify_calls;
  if (verify_status != SHIROHA_NATIVE_OK) return verify_status;
  if (point_length != sizeof(point_fixture) ||
      std::memcmp(point, point_fixture, sizeof(point_fixture)) != 0 ||
      std::memcmp(digest, digest_fixture, sizeof(digest_fixture)) != 0) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  return std::memcmp(raw, raw_fixture, sizeof(raw_fixture)) == 0
             ? SHIROHA_NATIVE_OK
             : SHIROHA_NATIVE_VERIFICATION_REJECTED;
}

const shiroha_native::CryptoOperations fake{fake_generate, fake_sign,
                                            fake_verify};
}  // namespace


void key_codec_contracts() {
  // RFC 6979 A.2.5 public test key, never a production credential.
  const char* scalar_hex="c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721";
  const char* point_hex="0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299";
  auto hex=[](const char* text,uint8_t* out,size_t count) {
    auto digit=[](char c) {return c<='9'?c-'0':c-'a'+10;};
    for(size_t i=0;i<count;++i) out[i]=static_cast<uint8_t>((digit(text[2*i])<<4)|digit(text[2*i+1]));
  };
  uint8_t scalar[32], point[65], output[256]{}, decoded[32]{};
  hex(scalar_hex,scalar,32); hex(point_hex,point,65);
  size_t length=0;
  check(shiroha_native::encode_p256_pkcs8(scalar,point,output,sizeof(output),&length),"PKCS8 encode");
  check(length==138 && output[0]==0x30 && output[1]==0x81 && output[2]==0x87,"PKCS8 frozen length");
  uint8_t expected[138]{};
  hex("308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420",expected,36);
  std::memcpy(expected+36,scalar,32);
  hex("a144034200",expected+68,5); std::memcpy(expected+73,point,65);
  check(std::memcmp(output,expected,138)==0,"OpenSSL-verified PKCS8 golden bytes");

  check(shiroha_native::decode_p256_pkcs8(output,length,point,decoded),"PKCS8 decode");
  check(std::memcmp(decoded,scalar,32)==0,"PKCS8 scalar");
  // Independently fixed PKCS#8 with absent optional publicKey, 67 bytes.
  uint8_t minimal[67]{};
  hex("3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420",minimal,35);
  std::memcpy(minimal+35,scalar,32);
  check(shiroha_native::decode_p256_pkcs8(minimal,sizeof(minimal),point,decoded),"PKCS8 optional public absent");
  for(size_t i=0;i<length;++i) check(!shiroha_native::decode_p256_pkcs8(output,i,point,decoded),"PKCS8 truncation");
  output[length]=0;
  check(!shiroha_native::decode_p256_pkcs8(output,length+1,point,decoded),"PKCS8 trailing");
  output[15]^=1;
  check(!shiroha_native::decode_p256_pkcs8(output,length,point,decoded),"PKCS8 wrong OID"); output[15]^=1;
  point[1]^=1;
  check(!shiroha_native::decode_p256_pkcs8(output,length,point,decoded),"PKCS8 wrong public"); point[1]^=1;
  std::memset(minimal+35,0,32);
  check(!shiroha_native::decode_p256_pkcs8(minimal,sizeof(minimal),point,decoded),"PKCS8 zero scalar");
  std::memset(minimal+35,255,32);
  check(!shiroha_native::decode_p256_pkcs8(minimal,sizeof(minimal),point,decoded),"PKCS8 scalar range");
  check(!shiroha_native::encode_p256_pkcs8(scalar,point,output,137,&length) && length==0,"PKCS8 short output");
}
int main() {
  key_codec_contracts();
  for (size_t i = 0; i < sizeof(pkcs8_fixture); ++i) {
    pkcs8_fixture[i] = static_cast<uint8_t>(i + 1);
  }
  point_fixture[0] = 0x04;
  for (size_t i = 1; i < sizeof(point_fixture); ++i) {
    point_fixture[i] = static_cast<uint8_t>(0x30 + i);
  }
  for (size_t i = 0; i < sizeof(digest_fixture); ++i) {
    digest_fixture[i] = static_cast<uint8_t>(0x50 + i);
  }
  for (size_t i = 0; i < sizeof(raw_fixture); ++i) {
    raw_fixture[i] = static_cast<uint8_t>(0x70 + i);
  }

  const auto version = SHIROHA_NATIVE_ABI_VERSION;
  uint8_t pkcs8[SHIROHA_NATIVE_ECDSA_PKCS8_MAX];
  uint8_t point[SHIROHA_NATIVE_ECDSA_POINT_BYTES];
  uint8_t digest[SHIROHA_NATIVE_ECDSA_DIGEST_BYTES];
  uint8_t signature[SHIROHA_NATIVE_ECDSA_RAW_BYTES];
  uint64_t written = 0, point_written = 0;
  std::memcpy(digest, digest_fixture, sizeof(digest));

  // ABI gate: the new exports accept ABI 3 only, never 1/2/4 or 0.
  for (const uint32_t bad : {0u, 1u, 2u, 4u, 99u}) {
    check(shiroha_native::generate_key(bad, pkcs8, sizeof(pkcs8), &written,
                                       point, sizeof(point), &point_written,
                                       fake) == SHIROHA_NATIVE_ABI_MISMATCH,
          "generate version gate");
    check(shiroha_native::sign_digest(bad, pkcs8_fixture,
                                      sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                      sizeof(digest), signature,
                                      sizeof(signature), &written,
                                      fake) == SHIROHA_NATIVE_ABI_MISMATCH,
          "sign version gate");
    check(shiroha_native::verify_digest(bad, point_fixture,
                                        sizeof(point_fixture), digest,
                                        sizeof(digest), raw_fixture,
                                        sizeof(raw_fixture),
                                        fake) == SHIROHA_NATIVE_ABI_MISMATCH,
          "verify version gate");
  }

  // Normal key generation: PKCS#8 length and the fixed 65-byte point.
  std::memset(pkcs8, kFill, sizeof(pkcs8));
  std::memset(point, kFill, sizeof(point));
  written = 123;
  point_written = 456;
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_OK,
        "generate ok");
  check(written == sizeof(pkcs8_fixture), "generate length");
  check(point_written == sizeof(point_fixture), "generate point length");
  check(std::memcmp(pkcs8, pkcs8_fixture, sizeof(pkcs8_fixture)) == 0,
        "generate pkcs8 bytes");
  check(std::memcmp(point, point_fixture, sizeof(point_fixture)) == 0,
        "generate point bytes");
  check(allBytes(pkcs8 + written, sizeof(pkcs8) - written, 0),
        "generate tail cleared");

  // Empty, oversized and null capacities are rejected before the fake runs.
  check(shiroha_native::generate_key(version, pkcs8, 0, &written, point,
                                     sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "generate zero capacity");
  check(shiroha_native::generate_key(version, pkcs8,
                                     SHIROHA_NATIVE_ECDSA_PKCS8_MAX + 1,
                                     &written, point, sizeof(point),
                                     &point_written,
                                     fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "generate oversized capacity");
  check(shiroha_native::generate_key(version, nullptr, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "generate null key");
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point) - 1, &point_written,
                                     fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "generate short point buffer");
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), nullptr,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "generate null count");
  const auto before_calls = generate_calls;
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_OK,
        "generate recovered");
  check(generate_calls == before_calls + 1, "generate call count");

  // Aliased buffers are rejected before any output is touched, and the input
  // is not cleared.
  {
    uint8_t aliased[SHIROHA_NATIVE_ECDSA_PKCS8_MAX];
    std::memset(aliased, kFill, sizeof(aliased));
    written = 7;
    check(shiroha_native::generate_key(version, aliased, sizeof(aliased),
                                       &written, aliased, sizeof(aliased),
                                       &point_written,
                                       fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "generate alias");
    check(written == 0 && point_written == 0, "generate alias counts cleared");
  }

  // Fake failure: the status passes through and both outputs are wiped.
  generate_status = SHIROHA_NATIVE_UNAVAILABLE;
  std::memset(pkcs8, kFill, sizeof(pkcs8));
  std::memset(point, kFill, sizeof(point));
  written = 9;
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_UNAVAILABLE,
        "generate failure status");
  check(written == 0 && point_written == 0, "generate failure counts");
  check(allBytes(pkcs8, sizeof(pkcs8), 0), "generate failure wipes key");
  check(allBytes(point, sizeof(point), 0), "generate failure wipes point");
  generate_status = SHIROHA_NATIVE_OK;

  // An out-of-range length is dataCorrupt, never success.
  generate_length = SHIROHA_NATIVE_ECDSA_PKCS8_MAX + 1;
  written = 3;
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_DATA_CORRUPT,
        "generate oversized result");
  check(written == 0 && point_written == 0, "generate oversized counts");
  generate_length = 0;
  check(shiroha_native::generate_key(version, pkcs8, sizeof(pkcs8), &written,
                                     point, sizeof(point), &point_written,
                                     fake) == SHIROHA_NATIVE_DATA_CORRUPT,
        "generate empty result");
  generate_length = sizeof(pkcs8_fixture);

  // Signing: fixed 64 bytes of raw r||s.
  std::memset(signature, kFill, sizeof(signature));
  written = 5;
  check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                    sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                    sizeof(digest), signature,
                                    sizeof(signature), &written,
                                    fake) == SHIROHA_NATIVE_OK,
        "sign ok");
  check(written == sizeof(raw_fixture), "sign length");
  check(std::memcmp(signature, raw_fixture, sizeof(raw_fixture)) == 0,
        "sign bytes");

  // The digest must be exactly 32 bytes; key length 1..256; output >= 64.
  for (const uint64_t bad_digest : {0ull, 16ull, 31ull, 33ull, 64ull}) {
    check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                      sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest, bad_digest,
                                      signature, sizeof(signature), &written,
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "sign digest length");
  }
  for (const uint64_t bad_key : {0ull, 257ull}) {
    check(shiroha_native::sign_digest(version, pkcs8_fixture, bad_key, point_fixture, sizeof(point_fixture), digest,
                                      sizeof(digest), signature,
                                      sizeof(signature), &written,
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "sign key length");
  }
  check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                    sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                    sizeof(digest), signature,
                                    sizeof(signature) - 1, &written,
                                    fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "sign short output");
  check(shiroha_native::sign_digest(version, nullptr, sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest, sizeof(digest), signature,
                                    sizeof(signature), &written,
                                    fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "sign null key");
  check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                    sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                    sizeof(digest), signature, sizeof(signature),
                                    nullptr,
                                    fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "sign null count");

  // A signing failure wipes the output and keeps written = 0.
  sign_status = SHIROHA_NATIVE_DATA_CORRUPT;
  std::memset(signature, kFill, sizeof(signature));
  written = 11;
  check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                    sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                    sizeof(digest), signature,
                                    sizeof(signature), &written,
                                    fake) == SHIROHA_NATIVE_DATA_CORRUPT,
        "sign failure status");
  check(written == 0, "sign failure count");
  check(allBytes(signature, sizeof(signature), 0), "sign failure wipes output");
  sign_status = SHIROHA_NATIVE_OK;

  // Aliasing: output overlapping key/digest/count is rejected without
  // clearing the input.
  {
    uint8_t aliased[SHIROHA_NATIVE_ECDSA_PKCS8_MAX];
    std::memset(aliased, kFill, sizeof(aliased));
    check(shiroha_native::sign_digest(version, aliased, 67, point_fixture, sizeof(point_fixture), digest,
                                      sizeof(digest), aliased,
                                      sizeof(aliased), &written,
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "sign output aliases key");
    check(aliased[0] == kFill, "sign alias keeps input");
    check(shiroha_native::sign_digest(version, pkcs8_fixture,
                                      sizeof(pkcs8_fixture), point_fixture, sizeof(point_fixture), digest,
                                      sizeof(digest), digest, sizeof(signature),
                                      &written,
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "sign output aliases digest");
  }

  {
    alignas(8) uint8_t input[256]; std::memset(input,kFill,sizeof(input));
    check(shiroha_native::sign_digest(version,input,67,point_fixture,65,digest,32,
      signature,64,reinterpret_cast<uint64_t*>(input),fake)==SHIROHA_NATIVE_INVALID_INPUT,"sign input/count alias");
    check(allBytes(input,sizeof(input),kFill),"count alias preserves input");
    check(shiroha_native::generate_key(version,input,256,reinterpret_cast<uint64_t*>(input),
      point,65,&point_written,fake)==SHIROHA_NATIVE_INVALID_INPUT,"generate count/output alias");
    check(allBytes(input,sizeof(input),kFill),"generate alias untouched");
    check(shiroha_native::sign_digest(version,pkcs8_fixture,67,point_fixture,65,digest,32,
      signature,UINT64_MAX,&written,fake)==SHIROHA_NATIVE_INVALID_INPUT,"sign overflow extent");
    check(shiroha_native::generate_key(version,pkcs8,256,&written,point,UINT64_MAX,
      &point_written,fake)==SHIROHA_NATIVE_INVALID_INPUT,"generate overflow extent");
  }

  // Verification: success, mismatch, wrong lengths and a malformed key.
  check(shiroha_native::verify_digest(version, point_fixture,
                                      sizeof(point_fixture), digest,
                                      sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_OK,
        "verify ok");
  uint8_t tampered[SHIROHA_NATIVE_ECDSA_RAW_BYTES];
  std::memcpy(tampered, raw_fixture, sizeof(tampered));
  tampered[0] ^= 0x01;
  check(shiroha_native::verify_digest(version, point_fixture,
                                      sizeof(point_fixture), digest,
                                      sizeof(digest), tampered,
                                      sizeof(tampered),
                                      fake) ==
            SHIROHA_NATIVE_VERIFICATION_REJECTED,
        "verify rejects tampered signature");
  for (const uint64_t bad : {0ull, 64ull, 66ull}) {
    check(shiroha_native::verify_digest(version, point_fixture, bad, digest,
                                        sizeof(digest), raw_fixture,
                                        sizeof(raw_fixture),
                                        fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "verify point length");
  }
  for (const uint64_t bad : {0ull, 31ull, 33ull}) {
    check(shiroha_native::verify_digest(version, point_fixture,
                                        sizeof(point_fixture), digest, bad,
                                        raw_fixture, sizeof(raw_fixture),
                                        fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "verify digest length");
  }
  for (const uint64_t bad : {0ull, 63ull, 65ull}) {
    check(shiroha_native::verify_digest(version, point_fixture,
                                        sizeof(point_fixture), digest,
                                        sizeof(digest), raw_fixture, bad,
                                        fake) == SHIROHA_NATIVE_INVALID_INPUT,
          "verify signature length");
  }
  check(shiroha_native::verify_digest(version, nullptr, sizeof(point_fixture),
                                      digest, sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "verify null key");

  uint8_t wrong_point[SHIROHA_NATIVE_ECDSA_POINT_BYTES];
  std::memcpy(wrong_point, point_fixture, sizeof(wrong_point));
  wrong_point[1] ^= 0xFF;
  check(shiroha_native::verify_digest(version, wrong_point,
                                      sizeof(wrong_point), digest,
                                      sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_DATA_CORRUPT,
        "verify malformed key");

  verify_status = SHIROHA_NATIVE_VERIFICATION_REJECTED;
  check(shiroha_native::verify_digest(version, point_fixture,
                                      sizeof(point_fixture), digest,
                                      sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_VERIFICATION_REJECTED,
        "verify pass-through rejection");
  verify_status = SHIROHA_NATIVE_ABI_MISMATCH;  // an unexpected class converges to dataCorrupt
  check(shiroha_native::verify_digest(version, point_fixture,
                                      sizeof(point_fixture), digest,
                                      sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_DATA_CORRUPT,
        "verify unexpected status");
  verify_status = SHIROHA_NATIVE_OK;

  // Mutually aliased inputs do no work at all.
  check(shiroha_native::verify_digest(version, point_fixture,
                                      sizeof(point_fixture), point_fixture,
                                      sizeof(digest), raw_fixture,
                                      sizeof(raw_fixture),
                                      fake) == SHIROHA_NATIVE_INVALID_INPUT,
        "verify alias");
  check(generate_calls > 0 && sign_calls > 0 && verify_calls > 0,
        "fake call coverage");

  std::cout << "PASS: fake-only ECDSA P-256 primitive contracts (no real CNG "
               "call, no LOCAL-L1 acceptance)\n";
  return 0;
}
