#ifndef SHIROHA_EXTERNAL_PEER_POLICY_H_
#define SHIROHA_EXTERNAL_PEER_POLICY_H_
#include "shiroha_external_native.h"
#include <cstddef>
namespace shiroha_native {
// Already decoded by crypt32, NEVER a hand-written DER parser. No certificate
// names, trust store, paths, keys, chain building or authorization in this seam.
struct PeerPolicy {
  bool v3 = false, signature_sha256 = false, signature_structure = false;
  bool p256 = false, valid_now = false, extensions_exact = false;
  bool leaf_constraints = false, digital_signature_only = false;
  bool server_auth_only = false, client_auth_only = false;
  bool single_loopback_san = false, san_absent = false;
};
struct PeerPolicyOperations {
  int32_t (*inspect)(const uint8_t*, size_t, PeerPolicy*) noexcept;
};
int32_t peer_policy(uint32_t version, const uint8_t* der, uint64_t length,
                    uint32_t role, const PeerPolicyOperations& ops) noexcept;
const PeerPolicyOperations& windows_peer_policy_operations() noexcept;
}  // namespace shiroha_native
#endif
