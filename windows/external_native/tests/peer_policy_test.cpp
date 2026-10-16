#include "peer_policy.h"
#include <cstdlib>
namespace {
shiroha_native::PeerPolicy source;
int32_t failure = 0;
int32_t inspect(const uint8_t*, size_t, shiroha_native::PeerPolicy* p) noexcept {
  *p = source;
  return failure;
}
void check(bool value) { if (!value) std::abort(); }
}
int main() {
  const uint8_t der[] = {1}; // NOT a certificate; tests decoded-policy orchestration only
  const shiroha_native::PeerPolicyOperations ops{inspect};
  source = {true,true,true,true,true,true,true,true,true,false,true,false};
  auto call = [&](uint32_t role) { return shiroha_native::peer_policy(3, der, 1, role, ops); };
  check(call(1) == 0); check(call(2) == 8);
  bool shiroha_native::PeerPolicy::* fields[] = {
    &shiroha_native::PeerPolicy::v3, &shiroha_native::PeerPolicy::signature_sha256,
    &shiroha_native::PeerPolicy::signature_structure, &shiroha_native::PeerPolicy::p256,
    &shiroha_native::PeerPolicy::valid_now, &shiroha_native::PeerPolicy::extensions_exact,
    &shiroha_native::PeerPolicy::leaf_constraints, &shiroha_native::PeerPolicy::digital_signature_only,
    &shiroha_native::PeerPolicy::server_auth_only, &shiroha_native::PeerPolicy::single_loopback_san};
  for (const auto field : fields) { source.*field = false; check(call(1) == 8); source.*field = true; }
  source.server_auth_only = false; source.single_loopback_san = false;
  source.client_auth_only = true; source.san_absent = true;
  check(call(2) == 0); check(call(1) == 8);
  source.san_absent = false; check(call(2) == 8);
  failure = 4; check(call(2) == 4); failure = 5; check(call(2) == 8);
  check(shiroha_native::peer_policy(2, der, 1, 1, ops) == 2);
  check(shiroha_native::peer_policy(3, nullptr, 1, 1, ops) == 1);
  check(shiroha_native::peer_policy(3, der, 16385, 1, ops) == 1);
  check(shiroha_native::peer_policy(3, der, 1, 3, ops) == 1);
}
