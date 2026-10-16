#include "peer_policy.h"
namespace shiroha_native {
int32_t peer_policy(uint32_t version, const uint8_t* der, uint64_t length,
                    uint32_t role, const PeerPolicyOperations& ops) noexcept {
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!der || length == 0 || length > 16384 || (role != 1 && role != 2))
    return SHIROHA_NATIVE_INVALID_INPUT;
  PeerPolicy p;
  const auto status = ops.inspect(der, static_cast<size_t>(length), &p);
  if (status != SHIROHA_NATIVE_OK) {
    return status == SHIROHA_NATIVE_UNAVAILABLE ? status : SHIROHA_NATIVE_VERIFICATION_REJECTED;
  }
  const bool role_ok = role == 1 ? p.server_auth_only && p.single_loopback_san :
                                   p.client_auth_only && p.san_absent;
  return p.v3 && p.signature_sha256 && p.signature_structure && p.p256 &&
      p.valid_now && p.extensions_exact && p.leaf_constraints &&
      p.digital_signature_only && role_ok ? SHIROHA_NATIVE_OK :
                                           SHIROHA_NATIVE_VERIFICATION_REJECTED;
}
}  // namespace shiroha_native
