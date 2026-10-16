#include "diagnostics/l1_native_observation.h"
#include "peer_policy.h"
#include <cstring>
// SDK prerequisite order is significant.
// clang-format off
#include <windows.h>
#include <wincrypt.h>
// clang-format on

namespace {
bool oid(const char* a, const char* b) noexcept {
  return a && std::strcmp(a, b) == 0;
}
template <typename T> struct Decoded {
  T* value = nullptr;
  L1_NATIVE_OWNER
  ~Decoded() {
    if (value)
      L1_NATIVE_RELEASE(
          kLocalFree, LocalFree(value),
          [](auto result) { return result == nullptr; },
          reinterpret_cast<HLOCAL>(1));
  }
  bool decode(LPCSTR type, const BYTE* data, DWORD size) noexcept {
    DWORD count = 0;
    const auto result = L1_NATIVE_CALL(
        kDecode,
        CryptDecodeObjectEx(X509_ASN_ENCODING, type, data, size,
                            CRYPT_DECODE_ALLOC_FLAG, nullptr, &value, &count),
        [](auto status) { return status != FALSE; }, FALSE);
    L1_NATIVE_ACQUIRED(value != nullptr);
    return result != FALSE;
  }
};
struct Certificate {
  PCCERT_CONTEXT value;
  L1_NATIVE_OWNER
  explicit Certificate(PCCERT_CONTEXT context) : value(context) {
    L1_NATIVE_ACQUIRED(value != nullptr);
  }
  ~Certificate() {
    if (value)
      L1_NATIVE_RELEASE(
          kCertFree, CertFreeCertificateContext(value),
          [](auto result) { return result != FALSE; }, FALSE);
  }
};
int32_t inspect(const uint8_t* der, size_t length,
                shiroha_native::PeerPolicy* p) noexcept {
  Certificate cert{L1_NATIVE_CALL(
      kCertCreate,
      CertCreateCertificateContext(X509_ASN_ENCODING, der,
                                   static_cast<DWORD>(length)),
      [](auto result) { return result != nullptr; },
      static_cast<PCCERT_CONTEXT>(nullptr))};
  if (!cert.value || !cert.value->pCertInfo) return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  const auto& c = *cert.value->pCertInfo;
  p->v3 = c.dwVersion == CERT_V3;
  Decoded<CERT_SIGNED_CONTENT_INFO> outer;
  if (!outer.decode(X509_CERT, der, static_cast<DWORD>(length)))
    return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  p->signature_sha256 = oid(c.SignatureAlgorithm.pszObjId, szOID_ECDSA_SHA256) &&
      c.SignatureAlgorithm.Parameters.cbData == 0 &&
      oid(outer.value->SignatureAlgorithm.pszObjId, szOID_ECDSA_SHA256) &&
      outer.value->SignatureAlgorithm.Parameters.cbData == 0;
  Decoded<CERT_ECC_SIGNATURE> sig;
  p->signature_structure = outer.value->Signature.cUnusedBits == 0 &&
      sig.decode(X509_ECC_SIGNATURE, outer.value->Signature.pbData,
                  outer.value->Signature.cbData) &&
      sig.value->r.cbData > 0 && sig.value->r.cbData <= 33 &&
      sig.value->s.cbData > 0 && sig.value->s.cbData <= 33;
  // Crypt32 independently decodes the curve OID; P21 is not policy authority.
  Decoded<char> curve;
  const auto& spki = c.SubjectPublicKeyInfo;
  p->p256 = oid(spki.Algorithm.pszObjId, szOID_ECC_PUBLIC_KEY) &&
      curve.decode(X509_OBJECT_IDENTIFIER, spki.Algorithm.Parameters.pbData,
                   spki.Algorithm.Parameters.cbData) &&
      oid(curve.value, szOID_ECC_CURVE_P256) &&
      spki.PublicKey.cUnusedBits == 0 && spki.PublicKey.cbData == 65 &&
      spki.PublicKey.pbData[0] == 4;
  p->valid_now =
      L1_NATIVE_CALL(
          kTime, CertVerifyTimeValidity(nullptr, cert.value->pCertInfo),
          [](auto result) { return result == 0; }, static_cast<LONG>(1)) == 0;
  const CERT_EXTENSION *bc = nullptr, *ku = nullptr, *eku = nullptr, *san = nullptr;
  if (c.cExtension != 3 && c.cExtension != 4) return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  for (DWORD i = 0; i < c.cExtension; ++i) {
    const auto* e = &c.rgExtension[i];
    const CERT_EXTENSION** target = nullptr;
    if (oid(e->pszObjId, szOID_BASIC_CONSTRAINTS2)) target = &bc;
    else if (oid(e->pszObjId, szOID_KEY_USAGE)) target = &ku;
    else if (oid(e->pszObjId, szOID_ENHANCED_KEY_USAGE)) target = &eku;
    else if (oid(e->pszObjId, szOID_SUBJECT_ALT_NAME2)) target = &san;
    else return SHIROHA_NATIVE_VERIFICATION_REJECTED; // no AIA/CRL/OCSP
    if (*target) return SHIROHA_NATIVE_VERIFICATION_REJECTED;
    *target = e;
  }
  if (!bc || !ku || !eku || !bc->fCritical || !ku->fCritical || eku->fCritical ||
      (san && !san->fCritical)) return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  p->extensions_exact = true;
  Decoded<CERT_BASIC_CONSTRAINTS2_INFO> constraints;
  p->leaf_constraints = constraints.decode(X509_BASIC_CONSTRAINTS2,
      bc->Value.pbData, bc->Value.cbData) && !constraints.value->fCA &&
      !constraints.value->fPathLenConstraint;
  Decoded<CRYPT_BIT_BLOB> usage;
  p->digital_signature_only = usage.decode(X509_KEY_USAGE, ku->Value.pbData,
      ku->Value.cbData) && usage.value->cbData == 1 &&
      usage.value->cUnusedBits == 7 && usage.value->pbData[0] == CERT_DIGITAL_SIGNATURE_KEY_USAGE;
  Decoded<CERT_ENHKEY_USAGE> enhanced;
  if (enhanced.decode(X509_ENHANCED_KEY_USAGE, eku->Value.pbData, eku->Value.cbData) &&
      enhanced.value->cUsageIdentifier == 1) {
    p->server_auth_only = oid(enhanced.value->rgpszUsageIdentifier[0], szOID_PKIX_KP_SERVER_AUTH);
    p->client_auth_only = oid(enhanced.value->rgpszUsageIdentifier[0], szOID_PKIX_KP_CLIENT_AUTH);
  }
  p->san_absent = san == nullptr;
  if (san) {
    Decoded<CERT_ALT_NAME_INFO> names;
    if (names.decode(X509_ALTERNATE_NAME, san->Value.pbData, san->Value.cbData) &&
        names.value->cAltEntry == 1) {
      const auto& entry = names.value->rgAltEntry[0];
      const BYTE loopback[] = {127, 0, 0, 1};
      p->single_loopback_san = entry.dwAltNameChoice == CERT_ALT_NAME_IP_ADDRESS &&
          entry.IPAddress.cbData == 4 && std::memcmp(entry.IPAddress.pbData, loopback, 4) == 0;
    }
  }
  return SHIROHA_NATIVE_OK;
}
}  // namespace
namespace shiroha_native {
const PeerPolicyOperations& windows_peer_policy_operations() noexcept {
  static const PeerPolicyOperations ops{inspect};
  return ops;
}
}  // namespace shiroha_native
extern "C" SHIROHA_NATIVE_API int32_t SHIROHA_NATIVE_CALL
shiroha_native_peer_certificate_policy(uint32_t version, const uint8_t* der,
                                      uint64_t length, uint32_t role) {
  return shiroha_native::peer_policy(version, der, length, role,
      shiroha_native::windows_peer_policy_operations());
}
