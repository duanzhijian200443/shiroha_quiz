// Future L1-CRYPTO isolated candidate only. Never registered in CTest and
// never executed without a separate reviewed batch grant.
#include "diagnostics/l1_crypto_probe.h"

#ifndef SHIROHA_L1_CRYPTO_FAKE_ONLY
#include <psapi.h>
#endif

#include <cstdio>

#ifndef SHIROHA_L1_CRYPTO_FAKE_ONLY
namespace {

bool sample_process_resources(
    shiroha_l1_crypto::L1CryptoLedger& ledger) noexcept {
  PROCESS_MEMORY_COUNTERS memory{};
  memory.cb = sizeof(memory);
  DWORD handles = 0;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory)) ||
      !GetProcessHandleCount(GetCurrentProcess(), &handles)) {
    return false;
  }
  return ledger.resources(memory.PeakWorkingSetSize, memory.PeakPagefileUsage,
                          handles);
}

bool monotonic_clock_ms(uint64_t& out_ms) noexcept {
  out_ms = GetTickCount64();
  return true;
}

void* resolve_static_allowed_symbol(const char* name) noexcept {
  if (!shiroha_l1_crypto::is_allowed_l1_crypto_symbol(name)) return nullptr;
  if (std::strcmp(name, "shiroha_native_abi_version") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_abi_version);
  }
  if (std::strcmp(name, "shiroha_native_buffer_alloc") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_buffer_alloc);
  }
  if (std::strcmp(name, "shiroha_native_buffer_free") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_buffer_free);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_generate_key") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_ecdsa_generate_key);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_sign_digest") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_ecdsa_sign_digest);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_verify_digest") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_ecdsa_verify_digest);
  }
  if (std::strcmp(name, "shiroha_native_peer_certificate_policy") == 0) {
    return reinterpret_cast<void*>(&shiroha_native_peer_certificate_policy);
  }
  return nullptr;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  return shiroha_l1_crypto::l1_crypto_candidate_entry(
      argc, argv, []() noexcept -> int {
        shiroha_l1_crypto::L1CryptoLedger ledger;
        ledger.sample = sample_process_resources;
        ledger.clock_ms = monotonic_clock_ms;
        shiroha_l1_crypto::L1CryptoApi api{};
        if (!shiroha_l1_crypto::resolve_l1_crypto_api(
                ledger, resolve_static_allowed_symbol, api)) {
          return 10;
        }
        return shiroha_l1_crypto::run_l1_crypto_sequence(api, ledger);
      });
}
#endif
