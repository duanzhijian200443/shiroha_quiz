#include "diagnostics/l1_crypto_probe.h"
#include <cstdlib>
#include <iostream>
#include <map>
#include <stdexcept>

using namespace shiroha_l1_crypto;
namespace {
void check(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}
struct FakeState {
  NativeOp failure = NativeOp::kCount;
  unsigned fail_occurrence = 1;
  bool throws = false;
  bool boundary_failed = false;
  bool also_fail_close = false;
  std::array<unsigned, kNativeOpCount> calls{};
  std::map<const void *, size_t> objects;
  std::map<const void *, unsigned> release_attempts;
  bool server = true;
  bool before(NativeOp op) {
    const bool cleanup = op == NativeOp::kClose || op == NativeOp::kDestroy ||
                         op == NativeOp::kCertFree ||
                         op == NativeOp::kLocalFree;
    check(!boundary_failed || cleanup,
          "no new business native calls after failure");
    const auto occurrence = ++calls[static_cast<size_t>(op)];
    if (also_fail_close && op == NativeOp::kClose) {
      boundary_failed = true;
      return false;
    }
    if (op != failure || occurrence != fail_occurrence) return true;
    boundary_failed = true;
    if (throws) throw std::runtime_error("FAKE_ONLY");
    return false;
  }
  void *allocate(size_t size) {
    void *p = std::calloc(1, size);
    check(p != nullptr, "fake allocation");
    objects[p] = size;
    release_attempts[p] = 0;
    return p;
  }
  void attempt_release(const void *p) {
    check(++release_attempts[p] == 1,
          "at most one release attempt per acquired object");
  }
  void release(const void *p) {
    check(objects.erase(p) == 1, "single release of owned Fake object");
    std::free(const_cast<void *>(p));
  }
  void reset() {
    // Fixture reclamation, never a second observed release of quarantined
    // owners.
    for (const auto &entry : objects)
      std::free(const_cast<void *>(entry.first));
    objects.clear();
    release_attempts.clear();
    calls.fill(0);
    failure = NativeOp::kCount;
    boundary_failed = false;
    also_fail_close = false;
    fail_occurrence = 1;
    throws = false;
    server = true;
  }
} env;
bool sample(L1CryptoLedger &ledger) noexcept {
  return ledger.resources(1024, 2048, 3);
}
bool clock_ms(uint64_t &ms) noexcept {
  ms = 10;
  return true;
}
L1CryptoApi api() {
  return {shiroha_native_abi_version,
          shiroha_native_buffer_alloc,
          shiroha_native_buffer_free,
          shiroha_native_ecdsa_generate_key,
          shiroha_native_ecdsa_sign_digest,
          shiroha_native_ecdsa_verify_digest,
          shiroha_native_peer_certificate_policy};
}
int sequence(NativeObservation &native, L1CryptoLedger &ledger) {
  NativeObservationScope scope(native);
  ledger.sample = sample;
  ledger.clock_ms = clock_ms;
  ledger.native_observation = &native;
  return run_l1_crypto_sequence(api(), ledger);
}
}  // namespace

NTSTATUS fake_BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *p, LPCWSTR,
                                          LPCWSTR, ULONG) {
  if (!env.before(NativeOp::kOpen)) return -1;
  *p = env.allocate(8);
  return 0;
}
NTSTATUS fake_BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE p, ULONG) {
  env.attempt_release(p);
  if (!env.before(NativeOp::kClose)) return -1;
  env.release(p);
  return 0;
}
NTSTATUS fake_BCryptGenerateKeyPair(BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE *p,
                                    ULONG, ULONG) {
  if (!env.before(NativeOp::kGenerate)) return -1;
  *p = env.allocate(8);
  return 0;
}
NTSTATUS fake_BCryptFinalizeKeyPair(BCRYPT_KEY_HANDLE, ULONG) {
  return env.before(NativeOp::kFinalize) ? 0 : -1;
}
NTSTATUS fake_BCryptExportKey(BCRYPT_KEY_HANDLE, BCRYPT_KEY_HANDLE, LPCWSTR,
                              PUCHAR out, ULONG capacity, ULONG *written,
                              ULONG) {
  if (!env.before(NativeOp::kExport)) return -1;
  check(capacity == 104, "ECC private blob capacity");
  auto *h = reinterpret_cast<BCRYPT_ECCKEY_BLOB *>(out);
  h->dwMagic = BCRYPT_ECDSA_PRIVATE_P256_MAGIC;
  h->cbKey = 32;
  std::memset(out + 8, 0x11, 64);
  std::memset(out + 72, 0, 32);
  out[103] = 1;
  *written = 104;
  return 0;
}
NTSTATUS fake_BCryptImportKeyPair(BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE, LPCWSTR,
                                  BCRYPT_KEY_HANDLE *p, PUCHAR, ULONG, ULONG) {
  if (!env.before(NativeOp::kImport)) return -1;
  *p = env.allocate(8);
  return 0;
}
NTSTATUS fake_BCryptSignHash(BCRYPT_KEY_HANDLE, void *, PUCHAR, ULONG,
                             PUCHAR out, ULONG capacity, ULONG *written,
                             ULONG) {
  if (!env.before(NativeOp::kSign)) return -1;
  check(capacity == 64, "raw signature capacity");
  std::memset(out, 0, 64);
  out[31] = out[63] = 1;
  *written = 64;
  return 0;
}
NTSTATUS fake_BCryptVerifySignature(BCRYPT_KEY_HANDLE, void *, PUCHAR, ULONG,
                                    PUCHAR signature, ULONG, ULONG) {
  if (!env.before(NativeOp::kVerify)) return -1;
  return signature[0] == 0 ? 0 : static_cast<NTSTATUS>(0xC000A000L);
}
NTSTATUS fake_BCryptDestroyKey(BCRYPT_KEY_HANDLE p) {
  env.attempt_release(p);
  if (!env.before(NativeOp::kDestroy)) return -1;
  env.release(p);
  return 0;
}

PCCERT_CONTEXT fake_CertCreateCertificateContext(DWORD, const BYTE *der,
                                                 DWORD length) {
  if (!env.before(NativeOp::kCertCreate)) return nullptr;
  const std::string bytes(reinterpret_cast<const char *>(der), length);
  env.server = bytes.find("Shiroha External Host") != std::string::npos;
  static BYTE dummy[] = {1};
  static BYTE point[65] = {4};
  static CERT_EXTENSION extensions[4]{};
  const char *oids[] = {szOID_BASIC_CONSTRAINTS2, szOID_KEY_USAGE,
                        szOID_ENHANCED_KEY_USAGE, szOID_SUBJECT_ALT_NAME2};
  for (size_t i = 0; i < 4; ++i) {
    extensions[i] = {const_cast<char *>(oids[i]), i != 2, {1, dummy}};
  }
  static CERT_INFO info{};
  info = {};
  info.dwVersion = CERT_V3;
  info.SignatureAlgorithm.pszObjId = const_cast<char *>(szOID_ECDSA_SHA256);
  info.SubjectPublicKeyInfo.Algorithm.pszObjId =
      const_cast<char *>(szOID_ECC_PUBLIC_KEY);
  info.SubjectPublicKeyInfo.Algorithm.Parameters = {1, dummy};
  info.SubjectPublicKeyInfo.PublicKey = {65, point, 0};
  info.cExtension = env.server ? 4 : 3;
  info.rgExtension = extensions;
  auto *context =
      static_cast<CERT_CONTEXT *>(env.allocate(sizeof(CERT_CONTEXT)));
  context->pCertInfo = &info;
  return context;
}
BOOL fake_CertFreeCertificateContext(PCCERT_CONTEXT p) {
  env.attempt_release(p);
  if (!env.before(NativeOp::kCertFree)) return FALSE;
  env.release(p);
  return TRUE;
}
BOOL fake_CryptDecodeObjectEx(DWORD, LPCSTR type, const BYTE *, DWORD, DWORD,
                              PCRYPT_DECODE_PARA, void *output, DWORD *) {
  if (!env.before(NativeOp::kDecode)) return FALSE;
  void *decoded = nullptr;
  static BYTE dummy[] = {1};
  if (type == X509_CERT) {
    auto *p = static_cast<CERT_SIGNED_CONTENT_INFO *>(
        env.allocate(sizeof(CERT_SIGNED_CONTENT_INFO)));
    p->SignatureAlgorithm.pszObjId = const_cast<char *>(szOID_ECDSA_SHA256);
    p->Signature = {1, dummy, 0};
    decoded = p;
  } else if (type == X509_ECC_SIGNATURE) {
    auto *p = static_cast<CERT_ECC_SIGNATURE *>(
        env.allocate(sizeof(CERT_ECC_SIGNATURE)));
    p->r.cbData = p->s.cbData = 32;
    decoded = p;
  } else if (type == X509_OBJECT_IDENTIFIER) {
    const size_t size = std::strlen(szOID_ECC_CURVE_P256) + 1;
    decoded = env.allocate(size);
    std::memcpy(decoded, szOID_ECC_CURVE_P256, size);
  } else if (type == X509_BASIC_CONSTRAINTS2) {
    decoded = env.allocate(sizeof(CERT_BASIC_CONSTRAINTS2_INFO));
  } else if (type == X509_KEY_USAGE) {
    static BYTE usage[] = {CERT_DIGITAL_SIGNATURE_KEY_USAGE};
    auto *p =
        static_cast<CRYPT_BIT_BLOB *>(env.allocate(sizeof(CRYPT_BIT_BLOB)));
    *p = {1, usage, 7};
    decoded = p;
  } else if (type == X509_ENHANCED_KEY_USAGE) {
    static char *oid = nullptr;
    oid = const_cast<char *>(env.server ? szOID_PKIX_KP_SERVER_AUTH
                                        : szOID_PKIX_KP_CLIENT_AUTH);
    auto *p = static_cast<CERT_ENHKEY_USAGE *>(
        env.allocate(sizeof(CERT_ENHKEY_USAGE)));
    p->cUsageIdentifier = 1;
    p->rgpszUsageIdentifier = &oid;
    decoded = p;
  } else if (type == X509_ALTERNATE_NAME) {
    static BYTE loopback[] = {127, 0, 0, 1};
    static CERT_ALT_NAME_ENTRY entry{};
    entry.dwAltNameChoice = CERT_ALT_NAME_IP_ADDRESS;
    entry.IPAddress = {4, loopback};
    auto *p = static_cast<CERT_ALT_NAME_INFO *>(
        env.allocate(sizeof(CERT_ALT_NAME_INFO)));
    p->cAltEntry = 1;
    p->rgAltEntry = &entry;
    decoded = p;
  } else
    check(false, "unexpected decode type");
  *static_cast<void **>(output) = decoded;
  return TRUE;
}
HLOCAL fake_LocalFree(HLOCAL p) {
  env.attempt_release(p);
  if (!env.before(NativeOp::kLocalFree)) return p;
  env.release(p);
  return nullptr;
}
LONG fake_CertVerifyTimeValidity(LPFILETIME, PCERT_INFO) {
  return env.before(NativeOp::kTime) ? 0 : 1;
}

int main() {
  {
    NativeObservation native;
    L1CryptoLedger ledger;
    check(sequence(native, ledger) == 0,
          "same wrappers succeed with Fake Win32");
    check(native.complete() && native.acquired == 47 && native.released == 47,
          "all 47 observed resources settled");
    check(ledger.abi_attempted_total == 106 && env.objects.empty(),
          "full ABI ledger");
    for (size_t i = 0; i < kNativeOpCount; ++i)
      check(env.calls[i] == kNativeLimits[i],
            "explicit underlying native budget");
  }
  unsigned cases = 0;
  for (size_t i = 0; i < kNativeOpCount; ++i) {
    // Every occurrence, not just the first acquisition/release in the program.
    for (unsigned occurrence = 1; occurrence <= kNativeLimits[i];
         ++occurrence) {
      for (bool throws : {false, true}) {
        env.reset();
        env.failure = static_cast<NativeOp>(i);
        env.fail_occurrence = occurrence;
        env.throws = throws;
        NativeObservation native;
        L1CryptoLedger ledger;
        check(sequence(native, ledger) == 10, "injected boundary stops");
        check(native.stopped && !native.complete(),
              "no false native settlement");
        const bool release = i == 7 || i == 8 || i == 10 || i == 12;
        check(release ? env.calls[i] >= occurrence : env.calls[i] == occurrence,
              "no retry; other owners may still settle once");
        if (release || throws) {
          check(native.unknown && std::strcmp(ledger.verdict(), "UNKNOWN") == 0,
                "release failure/exception remains UNKNOWN");
        } else
          check(std::strcmp(ledger.verdict(), "PASS") != 0, "refusal not PASS");
        check(ledger.buffers_live == 0,
              "ABI buffers still individually settled");
        check(native.still_owned == env.objects.size(),
              "quarantine agrees with Fake ownership");
        ++cases;
      }
    }
  }
  {
    env.reset();
    env.failure = NativeOp::kGenerate;
    env.also_fail_close = true;
    NativeObservation native;
    L1CryptoLedger ledger;
    check(sequence(native, ledger) == 10, "business and cleanup failure");
    check(std::strcmp(native.first_failure, "key_generate") == 0 &&
              std::strcmp(ledger.first_failure, "key_generate") == 0 &&
              std::strcmp(ledger.failure_code, "ADMISSION_BLOCKED") == 0 &&
              std::strcmp(ledger.verdict(), "UNKNOWN") == 0,
          "cleanup adds UNKNOWN without replacing the original failure");
  }
  env.reset();
  std::cout << "PASS: observed wrapper Fake boundaries=" << cases
            << "; no real CNG/crypt32, no retry, UNKNOWN retained\n";
}
