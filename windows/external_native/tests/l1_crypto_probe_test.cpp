#define SHIROHA_L1_CRYPTO_FAKE_ONLY
#include "diagnostics/l1_crypto_probe.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using namespace shiroha_l1_crypto;

void require(bool condition, const char* reason) {
  if (!condition) {
    std::cerr << "FAIL: " << reason << "\n";
    std::abort();
  }
}

struct FakeEnvironment {
  std::map<uintptr_t, std::vector<uint8_t>> live_allocations;
  unsigned alloc_calls = 0;
  unsigned free_calls = 0;
  unsigned fail_alloc_at = 0;
  bool throw_on_alloc = false;
  unsigned throw_on_free_at = 0;

  unsigned op_calls = 0;
  unsigned throw_at_op = 0;
  unsigned fail_status_at_op = 0;
  int injected_status = SHIROHA_NATIVE_UNAVAILABLE;
  unsigned bad_shape_at_op = 0;
  uint32_t abi_value = SHIROHA_NATIVE_ABI_VERSION;

  bool mismatch_negative_verify = false;
  bool mismatch_negative_policy = false;
  int negative_override_status = -1;

  unsigned sample_calls = 0;
  unsigned fail_sample_at = 0;
  uint64_t sample_working_set = 16ull * 1024 * 1024;
  uint64_t sample_commit = 24ull * 1024 * 1024;
  uint32_t sample_handles = 42;

  uint64_t now_ms = 1000;
  uint64_t step_ms = 100;
  unsigned timeout_at_clock_call = 0;
  unsigned clock_calls = 0;
  bool clock_fails = false;
  bool clock_backwards = false;

  unsigned generate_count = 0;
  unsigned sign_count = 0;
  unsigned verify_count = 0;
  unsigned policy_count = 0;
  std::vector<uint32_t> policy_roles_seen;
  std::vector<size_t> policy_cert_sizes;

  void reset() {
    live_allocations.clear();
    alloc_calls = free_calls = fail_alloc_at = throw_on_free_at = 0;
    throw_on_alloc = false;
    op_calls = throw_at_op = fail_status_at_op = bad_shape_at_op = 0;
    injected_status = SHIROHA_NATIVE_UNAVAILABLE;
    abi_value = SHIROHA_NATIVE_ABI_VERSION;
    mismatch_negative_verify = mismatch_negative_policy = false;
    negative_override_status = -1;
    sample_calls = fail_sample_at = 0;
    sample_working_set = 16ull * 1024 * 1024;
    sample_commit = 24ull * 1024 * 1024;
    sample_handles = 42;
    now_ms = 1000;
    step_ms = 100;
    timeout_at_clock_call = clock_calls = 0;
    clock_fails = clock_backwards = false;
    generate_count = sign_count = verify_count = policy_count = 0;
    policy_roles_seen.clear();
    policy_cert_sizes.clear();
  }
};

FakeEnvironment env;

// Deterministic non-secret test scalar/signature material in (0, n).
void fill_valid_raw_signature(const uint8_t* digest, uint8_t out_raw[64]) {
  for (size_t i = 0; i < 32; ++i) {
    out_raw[i] = static_cast<uint8_t>((digest[i] ^ 0x3cu) | 0x01u);
    out_raw[32 + i] = static_cast<uint8_t>((digest[31 - i] ^ 0x65u) | 0x01u);
  }
  // Ensure r and s have high bit set on index 0 in at least one component to
  // exercise ASN.1 DER leading-zero integer padding in X.509 ECDSA-Sig-Value,
  // while keeping both strictly < kP256Order (which starts with 0xff 0xff 0xff 0xff 0x00).
  out_raw[0] = 0x80u;
  out_raw[32] = 0x91u;
}

uint32_t SHIROHA_NATIVE_CALL fake_abi() {
  const unsigned current = ++env.op_calls;
  if (current == env.throw_at_op) {
    throw std::runtime_error("synthetic abi exception");
  }
  if (current == env.fail_status_at_op) return 2u;
  if (current == env.bad_shape_at_op) return 99u;
  return env.abi_value;
}

uint8_t* SHIROHA_NATIVE_CALL fake_alloc(uint64_t capacity) {
  const unsigned call = ++env.alloc_calls;
  if (env.throw_on_alloc) {
    throw std::runtime_error("synthetic alloc exception");
  }
  if (capacity == 0 || capacity > SHIROHA_NATIVE_MAX_BYTES ||
      call == env.fail_alloc_at) {
    return nullptr;
  }
  auto& vec = env.live_allocations[call];
  vec.assign(static_cast<size_t>(capacity), 0u);
  uint8_t* ptr = vec.data();
  auto moved = std::move(vec);
  env.live_allocations.erase(call);
  env.live_allocations[reinterpret_cast<uintptr_t>(ptr)] = std::move(moved);
  return env.live_allocations[reinterpret_cast<uintptr_t>(ptr)].data();
}

void SHIROHA_NATIVE_CALL fake_free(uint8_t* buffer) {
  const unsigned call = ++env.free_calls;
  require(buffer != nullptr, "null buffer free");
  const auto key = reinterpret_cast<uintptr_t>(buffer);
  const auto it = env.live_allocations.find(key);
  require(it != env.live_allocations.end(), "unknown or double-freed buffer");
  // Verify caller wiped the buffer before releasing it.
  for (uint8_t byte : it->second) {
    require(byte == 0u, "buffer not zeroed before free");
  }
  env.live_allocations.erase(it);
  if (call == env.throw_on_free_at) {
    throw std::runtime_error("synthetic free exception");
  }
}

int32_t SHIROHA_NATIVE_CALL fake_generate_key(
    uint32_t version, uint8_t* private_key, uint64_t private_capacity,
    uint64_t* private_written, uint8_t* public_key, uint64_t public_capacity,
    uint64_t* public_written) {
  const unsigned current = ++env.op_calls;
  ++env.generate_count;
  if (current == env.throw_at_op) {
    throw std::runtime_error("synthetic generate exception");
  }
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (current == env.fail_status_at_op) return env.injected_status;
  require(private_capacity == SHIROHA_NATIVE_ECDSA_PKCS8_MAX,
          "generate key capacity");
  require(public_capacity == SHIROHA_NATIVE_ECDSA_POINT_BYTES,
          "generate point capacity");
  // Fill with distinct non-secret synthetic marker bytes (0xaa / 0xbb) to
  // prove redaction and private-key wiping.
  std::memset(private_key, static_cast<int>(0xa0u + env.generate_count), 138);
  public_key[0] = 0x04u;
  std::memset(public_key + 1, static_cast<int>(0xb0u + env.generate_count), 64);
  *private_written = (current == env.bad_shape_at_op) ? 0ull : 138ull;
  *public_written =
      (current == env.bad_shape_at_op) ? 64ull : SHIROHA_NATIVE_ECDSA_POINT_BYTES;
  return SHIROHA_NATIVE_OK;
}

int32_t SHIROHA_NATIVE_CALL fake_sign_digest(
    uint32_t version, const uint8_t* private_key, uint64_t private_length,
    const uint8_t* public_key, uint64_t public_length, const uint8_t* digest,
    uint64_t digest_length, uint8_t* signature, uint64_t signature_capacity,
    uint64_t* signature_written) {
  const unsigned current = ++env.op_calls;
  ++env.sign_count;
  if (current == env.throw_at_op) {
    throw std::runtime_error("synthetic sign exception");
  }
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (current == env.fail_status_at_op) return env.injected_status;
  require(private_key != nullptr && private_length == 138, "sign key length");
  require(public_key != nullptr &&
              public_length == SHIROHA_NATIVE_ECDSA_POINT_BYTES &&
              public_key[0] == 0x04u,
          "sign public point");
  require(digest != nullptr &&
              digest_length == SHIROHA_NATIVE_ECDSA_DIGEST_BYTES,
          "sign digest length");
  require(signature != nullptr &&
              signature_capacity == SHIROHA_NATIVE_ECDSA_RAW_BYTES,
          "sign signature capacity");
  fill_valid_raw_signature(digest, signature);
  *signature_written =
      (current == env.bad_shape_at_op) ? 63ull : SHIROHA_NATIVE_ECDSA_RAW_BYTES;
  return SHIROHA_NATIVE_OK;
}

int32_t SHIROHA_NATIVE_CALL fake_verify_digest(
    uint32_t version, const uint8_t* public_key, uint64_t public_length,
    const uint8_t* digest, uint64_t digest_length, const uint8_t* signature,
    uint64_t signature_length) {
  const unsigned current = ++env.op_calls;
  ++env.verify_count;
  if (current == env.throw_at_op) {
    throw std::runtime_error("synthetic verify exception");
  }
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (current == env.fail_status_at_op) return env.injected_status;
  require(public_key != nullptr &&
              public_length == SHIROHA_NATIVE_ECDSA_POINT_BYTES &&
              public_key[0] == 0x04u,
          "verify point");
  require(digest != nullptr &&
              digest_length == SHIROHA_NATIVE_ECDSA_DIGEST_BYTES,
          "verify digest");
  require(signature != nullptr &&
              signature_length == SHIROHA_NATIVE_ECDSA_RAW_BYTES,
          "verify signature");
  uint8_t expected[64]{};
  fill_valid_raw_signature(digest, expected);
  const bool matches = (std::memcmp(signature, expected, 64) == 0);
  if (!matches) {
    if (env.mismatch_negative_verify) return SHIROHA_NATIVE_OK;
    if (env.negative_override_status >= 0) return env.negative_override_status;
    return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  }
  return SHIROHA_NATIVE_OK;
}

int32_t SHIROHA_NATIVE_CALL fake_peer_policy(uint32_t version,
                                             const uint8_t* der,
                                             uint64_t length, uint32_t role) {
  const unsigned current = ++env.op_calls;
  ++env.policy_count;
  env.policy_roles_seen.push_back(role);
  env.policy_cert_sizes.push_back(static_cast<size_t>(length));
  if (current == env.throw_at_op) {
    throw std::runtime_error("synthetic policy exception");
  }
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (current == env.fail_status_at_op) return env.injected_status;
  if (!der || length == 0 || length > 16384 || (role != 1u && role != 2u)) {
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  // Check the role encoded in the DER certificate:
  // Server certificate contains subject "Shiroha External Host" and IP SAN
  // 127.0.0.1 (87 04 7f 00 00 1); Client certificate contains subject
  // "Shiroha External Bridge" and EKU clientAuth (2b 06 01 05 05 07 03 02).
  const std::string bytes(reinterpret_cast<const char*>(der),
                          static_cast<size_t>(length));
  const bool is_server_cert =
      bytes.find("Shiroha External Host") != std::string::npos &&
      bytes.find(std::string("\x87\x04\x7f\x00\x00\x01", 6)) !=
          std::string::npos;
  const bool is_client_cert =
      bytes.find("Shiroha External Bridge") != std::string::npos &&
      bytes.find(std::string("\x87\x04\x7f\x00\x00\x01", 6)) ==
          std::string::npos;
  const bool role_ok =
      (role == 1u && is_server_cert) || (role == 2u && is_client_cert);
  if (!role_ok) {
    if (env.mismatch_negative_policy) return SHIROHA_NATIVE_OK;
    if (env.negative_override_status >= 0) return env.negative_override_status;
    return SHIROHA_NATIVE_VERIFICATION_REJECTED;
  }
  return SHIROHA_NATIVE_OK;
}

bool fake_sample(L1CryptoLedger& ledger) noexcept {
  const unsigned count = ++env.sample_calls;
  if (count == env.fail_sample_at) return false;
  return ledger.resources(env.sample_working_set, env.sample_commit,
                          env.sample_handles);
}

bool fake_clock(uint64_t& out_ms) noexcept {
  const unsigned call = ++env.clock_calls;
  if (env.clock_fails) return false;
  if (env.clock_backwards && call >= 2) {
    out_ms = env.now_ms - 1;
    return true;
  }
  if (env.timeout_at_clock_call > 0 && call >= env.timeout_at_clock_call) {
    env.now_ms += 30001;
  } else if (call > 1) {
    env.now_ms += env.step_ms;
  }
  out_ms = env.now_ms;
  return true;
}

void* fake_symbol_lookup(const char* name) {
  if (std::strcmp(name, "shiroha_native_abi_version") == 0) {
    return reinterpret_cast<void*>(&fake_abi);
  }
  if (std::strcmp(name, "shiroha_native_buffer_alloc") == 0) {
    return reinterpret_cast<void*>(&fake_alloc);
  }
  if (std::strcmp(name, "shiroha_native_buffer_free") == 0) {
    return reinterpret_cast<void*>(&fake_free);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_generate_key") == 0) {
    return reinterpret_cast<void*>(&fake_generate_key);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_sign_digest") == 0) {
    return reinterpret_cast<void*>(&fake_sign_digest);
  }
  if (std::strcmp(name, "shiroha_native_ecdsa_verify_digest") == 0) {
    return reinterpret_cast<void*>(&fake_verify_digest);
  }
  if (std::strcmp(name, "shiroha_native_peer_certificate_policy") == 0) {
    return reinterpret_cast<void*>(&fake_peer_policy);
  }
  return nullptr;
}

void configure_ledger(L1CryptoLedger& ledger) {
  ledger.sample = fake_sample;
  ledger.clock_ms = fake_clock;
  ledger.working_set_limit_bytes = 64ull * 1024 * 1024;
  ledger.commit_limit_bytes = 64ull * 1024 * 1024;
  ledger.handle_limit = 128;
}

// 1. Normal sequence ledger, role checks, private-key wiping, and redaction.
void test_normal_sequence_and_redaction() {
  env.reset();
  L1CryptoLedger ledger;
  configure_ledger(ledger);
  L1CryptoApi api{};
  require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api),
          "resolve 7 allowed symbols");
  require(ledger.allowed_symbol_resolutions == 7 &&
              ledger.forbidden_symbol_attempts == 0,
          "symbol resolution counts");

  const int rc = run_l1_crypto_sequence(api, ledger);
  require(rc == 0, "normal sequence exit 0");
  require(!ledger.stopped, "normal sequence not stopped");
  require(std::strcmp(ledger.verdict(), "PASS") == 0, "verdict PASS");
  require(std::strcmp(ledger.failure_code, "NONE") == 0, "failure code NONE");
  require(ledger.attempted == 16 && ledger.returned == 16 &&
              ledger.completed == 16,
          "16 total calls attempted/returned/completed");
  // 1 abi + 3 gen + 3 sign + 3 valid verify + 2 valid policy = 12 status-0/ABI calls;
  // 3 negative verify + 1 negative policy = 4 expected rejections (status 8).
  require(ledger.successful == 12 && ledger.accepted == 16,
          "12 status-0 successful, 16 accepted");
  require(ledger.abi_reserved == 1 && ledger.generate_reserved == 3 &&
              ledger.encode_sign_reserved == 3 && ledger.verify_reserved == 6 &&
              ledger.verify_positive_reserved == 3 &&
              ledger.verify_negative_reserved == 3 &&
              ledger.policy_reserved == 3,
          "exact 1/3/3/6(3+3)/3 call ledger");
  require(env.generate_count == 3 && env.sign_count == 3 &&
              env.verify_count == 6 && env.policy_count == 3,
          "underlying fake call counts match ledger");
  require(env.policy_roles_seen == std::vector<uint32_t>({1u, 2u, 2u}),
          "policy roles server(1), client(2), mismatch(2)");
  require(env.live_allocations.empty(), "zero leaked native buffers");
  require(ledger.buffers_live == 0 &&
              ledger.buffers_allocated == ledger.releases_attempted &&
              ledger.releases_succeeded == ledger.buffers_allocated &&
              ledger.releases_unknown == 0 &&
              ledger.duplicate_release_attempts == 0,
          "every buffer released once");
  require(ledger.samples == 18 && ledger.observation_failures == 0,
          "18 resource samples (before, 16 steps, after)");

  const std::string summary = ledger.format_redacted_summary();
  require(summary.find("verdict=PASS") != std::string::npos,
          "summary contains verdict");
  require(summary.find("not_executed") == std::string::npos &&
              summary.find("not_completed") == std::string::npos,
          "all steps executed and completed");
  // Ensure no private key marker bytes, certificate strings or paths appear.
  for (const char* forbidden :
       {"a1a1", "a2a2", "a3a3", "b1b1", "Shiroha External", "C:\\", "Users"}) {
    require(summary.find(forbidden) == std::string::npos,
            "summary redacts keys/certs/paths");
  }
}

// 2. First failure stops immediately at every step (status failure, exception,
// and invalid output shape).
void test_first_failure_stops_immediately() {
  for (unsigned step = 1; step <= 16; ++step) {
    // Case A: status failure at step
    {
      env.reset();
      env.fail_status_at_op = step;
      L1CryptoLedger ledger;
      configure_ledger(ledger);
      L1CryptoApi api{};
      require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api),
              "resolve");
      const int rc = run_l1_crypto_sequence(api, ledger);
      require(rc == 10 && ledger.stopped, "status failure stops");
      require(env.op_calls == step && ledger.attempted == step &&
                  ledger.returned == step && ledger.completed == step,
              "no call after failed status");
      require(std::strcmp(ledger.first_failure,
                          L1CryptoLedger::kSteps[step - 1]) == 0,
              "first_failure matches exact step");
      require(std::strcmp(ledger.verdict(), "FAIL") == 0,
              "status failure verdict FAIL");
      require(env.live_allocations.empty() && ledger.buffers_live == 0,
              "buffers cleaned up once on status failure");
      const std::string summary = ledger.format_redacted_summary();
      if (step < 16) {
        require(summary.find(std::string("not_executed step=") +
                             L1CryptoLedger::kSteps[step]) != std::string::npos,
                "unexecuted step recorded");
      }
    }
    // Case B: thrown exception at step (consumes reservation, never returns)
    {
      env.reset();
      env.throw_at_op = step;
      L1CryptoLedger ledger;
      configure_ledger(ledger);
      L1CryptoApi api{};
      require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api),
              "resolve");
      const int rc = run_l1_crypto_sequence(api, ledger);
      require(rc == 10 && ledger.stopped && ledger.settlement_unknown,
              "exception marks settlement unknown");
      require(env.op_calls == step && ledger.attempted == step &&
                  ledger.returned == step - 1 && ledger.completed == step - 1,
              "throwing call consumes budget without returning");
      require(std::strcmp(ledger.failure_code, "SETTLEMENT_UNKNOWN") == 0 &&
                  std::strcmp(ledger.verdict(), "UNKNOWN") == 0,
              "exception verdict UNKNOWN");
      require(env.live_allocations.empty() && ledger.buffers_live == 0,
              "buffers cleaned up once after exception");
      const std::string summary = ledger.format_redacted_summary();
      require(summary.find(std::string("not_completed step=") +
                           L1CryptoLedger::kSteps[step - 1] +
                           " returned=0") != std::string::npos,
              "not_completed step recorded");
    }
  }
  // Case C: bad output shape despite status 0 on ABI, generate (1..3), sign (4..6)
  for (unsigned step : {1u, 2u, 3u, 4u, 5u, 6u, 7u}) {
    env.reset();
    env.bad_shape_at_op = step;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    const int rc = run_l1_crypto_sequence(api, ledger);
    require(rc == 10 && ledger.stopped && env.op_calls == step,
            "bad shape stops immediately");
    require(std::strcmp(ledger.first_failure,
                        L1CryptoLedger::kSteps[step - 1]) == 0,
            "bad shape first_failure");
    require(env.live_allocations.empty(), "bad shape releases buffers");
  }
}

// 3 & 4. Budget exhaustion and failed calls still consuming budget.
void test_budget_exhaustion_and_failed_call_consumption() {
  struct BudgetCase {
    PrimitiveCategory cat;
    unsigned limit;
  };
  const BudgetCase cases[] = {
      {PrimitiveCategory::kAbi, 1},
      {PrimitiveCategory::kGenerateKey, 3},
      {PrimitiveCategory::kCertificateEncodeSign, 3},
      {PrimitiveCategory::kVerifyPositive, 3},
      {PrimitiveCategory::kVerifyNegative, 3},
      {PrimitiveCategory::kPeerPolicyPositive, 3},
  };
  for (const auto& bc : cases) {
    env.reset();
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    unsigned underlying_calls = 0;
    for (unsigned i = 0; i < bc.limit; ++i) {
      const int expected =
          (bc.cat == PrimitiveCategory::kAbi)
              ? 3
              : ((bc.cat == PrimitiveCategory::kVerifyNegative) ? 8 : 0);
      require(ledger.invoke_and_check(
                  bc.cat, "abi", expected,
                  [&] {
                    ++underlying_calls;
                    return expected;
                  },
                  [](int) { return true; }),
              "within budget succeeds");
    }
    require(underlying_calls == bc.limit, "exact limit invoked");
    // Next call must be blocked BEFORE invoking the callback.
    const bool extra = ledger.invoke_and_check(
        bc.cat, "abi", 0,
        [&] {
          ++underlying_calls;
          return 0;
        },
        [](int) { return true; });
    require(!extra && underlying_calls == bc.limit,
            "over-budget call blocked before native invocation");
    require(ledger.budget_rejections == 1 &&
                std::strcmp(ledger.first_failure, "call_budget_exceeded") == 0 &&
                std::strcmp(ledger.failure_code, "BUDGET_EXCEEDED") == 0,
            "budget rejection recorded");
  }

  // Failed call consumes 1 budget slot and blocks subsequent calls.
  {
    env.reset();
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    unsigned calls = 0;
    const bool first = ledger.invoke_and_check(
        PrimitiveCategory::kGenerateKey, "gen_issuer", SHIROHA_NATIVE_OK,
        [&] {
          ++calls;
          return SHIROHA_NATIVE_UNAVAILABLE;
        },
        [](int) { return true; });
    require(!first && calls == 1 && ledger.generate_reserved == 1 &&
                ledger.attempted == 1,
            "failed call consumed 1 reservation");
    const bool retry = ledger.invoke_and_check(
        PrimitiveCategory::kGenerateKey, "gen_issuer", SHIROHA_NATIVE_OK,
        [&] {
          ++calls;
          return SHIROHA_NATIVE_OK;
        },
        [](int) { return true; });
    require(!retry && calls == 1 && ledger.generate_reserved == 1,
            "no retry after failed call");
  }
}

// 5. Expected rejection vs unexpected pass/error distinction.
void test_expected_rejection_vs_unexpected_outcomes() {
  // Negative verify returning OK -> SECURITY_REJECT_MISMATCH
  {
    env.reset();
    env.mismatch_negative_verify = true;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10, "mismatch stops");
    require(std::strcmp(ledger.first_failure, "verify_issuer_tampered") == 0 &&
                std::strcmp(ledger.failure_code, "SECURITY_REJECT_MISMATCH") ==
                    0,
            "tampered verify returning OK is SECURITY_REJECT_MISMATCH");
    require(env.op_calls == 11, "stops at first tampered verify (step 11)");
  }
  // Negative policy returning OK -> SECURITY_REJECT_MISMATCH
  {
    env.reset();
    env.mismatch_negative_policy = true;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10, "policy mismatch stops");
    require(std::strcmp(ledger.first_failure, "policy_role_mismatch") == 0 &&
                std::strcmp(ledger.failure_code, "SECURITY_REJECT_MISMATCH") ==
                    0,
            "role mismatch returning OK is SECURITY_REJECT_MISMATCH");
    require(env.op_calls == 16, "stops at step 16");
  }
  // Negative verify returning UNAVAILABLE (4) instead of VERIFICATION_REJECTED (8)
  {
    env.reset();
    env.negative_override_status = SHIROHA_NATIVE_UNAVAILABLE;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10,
            "unexpected negative error stops");
    require(std::strcmp(ledger.first_failure, "verify_issuer_tampered") == 0 &&
                std::strcmp(ledger.failure_code, "ADMISSION_BLOCKED") == 0,
            "unexpected negative status is ADMISSION_BLOCKED");
  }
}

// 6 & 7. DER ECDSA-Sig-Value vs 64-byte raw r||s boundary and certificate roles.
void test_der_raw_signature_boundary_and_certificate_roles() {
  uint8_t raw[64]{};
  uint8_t digest[32]{};
  for (size_t i = 0; i < 32; ++i) digest[i] = static_cast<uint8_t>(i + 1);
  fill_valid_raw_signature(digest, raw);

  std::vector<uint8_t> der_sig;
  require(raw_signature_to_der(raw, 64, der_sig), "valid raw -> DER");
  require(der_sig.size() == 72 && der_sig[0] == 0x30 && der_sig[2] == 0x02 &&
              der_sig[3] == 33 && der_sig[4] == 0x00,
          "high-bit r/s padded with leading 0x00 in DER");
  uint8_t roundtrip[64]{};
  require(der_signature_to_raw(der_sig.data(), der_sig.size(), roundtrip) &&
              std::memcmp(raw, roundtrip, 64) == 0,
          "DER -> raw lossless roundtrip");

  // Reject zero scalar, scalar >= order, wrong lengths, non-minimal DER integer
  uint8_t bad_raw[64]{};
  std::memcpy(bad_raw, raw, 64);
  std::memset(bad_raw, 0, 32);
  std::vector<uint8_t> out;
  require(!raw_signature_to_der(bad_raw, 64, out), "zero r rejected");
  std::memcpy(bad_raw, kP256Order, 32);
  require(!raw_signature_to_der(bad_raw, 64, out), "r == order rejected");
  require(!raw_signature_to_der(raw, 63, out), "short raw rejected");

  std::vector<uint8_t> non_minimal = der_sig;
  non_minimal[5] = 0x01;  // leading 0x00 followed by < 0x80 is non-minimal
  require(!der_signature_to_raw(non_minimal.data(), non_minimal.size(),
                                roundtrip),
          "non-minimal DER integer rejected");
  std::vector<uint8_t> trailing = der_sig;
  trailing.push_back(0x00);
  require(!der_signature_to_raw(trailing.data(), trailing.size(), roundtrip),
          "trailing DER bytes rejected");

  // Cross-check SHA-256 against NIST "abc" public vector
  const uint8_t abc[] = {'a', 'b', 'c'};
  uint8_t abc_digest[32]{};
  sha256_digest(abc, 3, abc_digest);
  const uint8_t expected_abc[32] = {
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
      0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
      0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
  require(std::memcmp(abc_digest, expected_abc, 32) == 0,
          "SHA-256 NIST abc vector");
}

// 8 & 9. Single release, duplicate release protection, and unknown release state.
void test_buffer_single_release_and_unknown_state() {
  // Duplicate release on the same slot is blocked without calling free twice.
  {
    env.reset();
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    L1CryptoBufferPool pool(api, ledger);
    uint8_t* ptr = nullptr;
    size_t slot = 0;
    require(pool.allocate(64, &ptr, &slot), "allocate");
    ptr[0] = 0x5au;
    require(pool.release(slot) && env.free_calls == 1, "first release ok");
    require(!pool.release(slot) && env.free_calls == 1,
            "second release blocked before native free");
    require(ledger.duplicate_release_attempts == 1 &&
                std::strcmp(ledger.failure_code, "OWNERSHIP_UNKNOWN") == 0 &&
                std::strcmp(ledger.verdict(), "FAIL") == 0,
            "duplicate release recorded as OWNERSHIP_UNKNOWN");
  }
  // Throwing free marks release_unknown and SETTLEMENT_UNKNOWN without retrying.
  {
    env.reset();
    env.throw_on_free_at = 1;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    const int rc = run_l1_crypto_sequence(api, ledger);
    require(rc == 10 && ledger.releases_unknown == 1,
            "throwing free marks release unknown");
    require(std::strcmp(ledger.failure_code, "SETTLEMENT_UNKNOWN") == 0 &&
                std::strcmp(ledger.verdict(), "UNKNOWN") == 0,
            "unknown release verdict is UNKNOWN");
    // Remaining 2 buffers from gen_issuer (allocated 3 total) were still each
    // released once; the throwing slot was never retried.
    require(ledger.buffers_allocated == 3 && ledger.releases_attempted == 3 &&
                ledger.releases_succeeded == 2 && env.free_calls == 3,
            "remaining buffers released once without retrying failed slot");
  }
}

// 10 & 11. Resource sampling failures, budget ceilings, and 30s timeout logic.
void test_resource_sampling_and_timeout_gates() {
  // Sampling failure at each of the 18 observation points (1..18)
  for (unsigned pt = 1; pt <= 18; ++pt) {
    env.reset();
    env.fail_sample_at = pt;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    const int rc = run_l1_crypto_sequence(api, ledger);
    require(rc == 10 && ledger.observation_failures == 1,
            "sampling failure stops sequence");
    require(std::strcmp(ledger.failure_code, "MEASUREMENT_UNAVAILABLE") == 0 &&
                std::strcmp(ledger.verdict(), "INCONCLUSIVE") == 0,
            "sampling failure verdict INCONCLUSIVE");
    require(env.op_calls == (pt == 1 ? 0 : (pt == 18 ? 16 : pt - 1)),
            "no further primitive calls after failed sample");
  }
  // Memory working set, commit, and handle ceilings
  for (int kind = 0; kind < 3; ++kind) {
    env.reset();
    if (kind == 0) env.sample_working_set = 64ull * 1024 * 1024 + 1;
    if (kind == 1) env.sample_commit = 64ull * 1024 * 1024 + 1;
    if (kind == 2) env.sample_handles = 129;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10,
            "ceiling excess stops before work");
    require(std::strcmp(ledger.failure_code, "BUDGET_EXCEEDED") == 0 &&
                env.op_calls == 0,
            "resource ceiling blocks calls");
  }
  // 30-second deadline exceeded before/during calls
  for (unsigned call : {2u, 5u, 12u, 30u}) {
    env.reset();
    env.timeout_at_clock_call = call;
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10, "timeout stops");
    require(std::strcmp(ledger.first_failure, "deadline_exceeded") == 0 &&
                std::strcmp(ledger.failure_code, "BUDGET_EXCEEDED") == 0,
            "timeout records BUDGET_EXCEEDED");
  }
  // Clock backwards / clock failure
  for (bool backwards : {false, true}) {
    env.reset();
    if (backwards) {
      env.clock_backwards = true;
    } else {
      env.clock_fails = true;
    }
    L1CryptoLedger ledger;
    configure_ledger(ledger);
    L1CryptoApi api{};
    require(resolve_l1_crypto_api(ledger, fake_symbol_lookup, api), "resolve");
    require(run_l1_crypto_sequence(api, ledger) == 10, "clock anomaly stops");
    require(std::strcmp(ledger.failure_code, "MEASUREMENT_UNAVAILABLE") == 0,
            "clock anomaly is MEASUREMENT_UNAVAILABLE");
  }
}

// 12, 13 & 14. Forbidden symbol resolution and default-deny candidate entry.
void test_forbidden_symbols_and_default_deny_entry() {
  // Every one of the 20 non-crypto ABI-3 exports is rejected before lookup.
  for (const char* forbidden : kForbiddenSymbols) {
    require(!is_allowed_l1_crypto_symbol(forbidden),
            "forbidden symbol not allowed");
    require(is_forbidden_abi_symbol(forbidden),
            "forbidden symbol flagged forbidden");
    L1CryptoLedger ledger;
    unsigned lookups = 0;
    void* target = nullptr;
    const bool resolved = resolve_symbol_checked(
        ledger, forbidden,
        [&](const char*) -> void* {
          ++lookups;
          return reinterpret_cast<void*>(&fake_abi);
        },
        target);
    require(!resolved && lookups == 0 && target == nullptr,
            "forbidden symbol never reaches lookup callback");
    require(ledger.forbidden_symbol_attempts == 1 &&
                std::strcmp(ledger.first_failure,
                            "forbidden_symbol_resolution") == 0 &&
                std::strcmp(ledger.failure_code, "UNAUTHORIZED_ACCESS") == 0,
            "forbidden symbol records UNAUTHORIZED_ACCESS");
  }

  // Default-deny candidate entry refuses every CLI shape without invoking work.
  const wchar_t* prog = L"shiroha_l1_crypto_candidate.exe";
  for (const wchar_t* arg :
       {L"l1-crypto", L"--run-once", L"execute", L"symbols", L"abi"}) {
    const wchar_t* argv2[] = {prog, arg};
    unsigned invoked = 0;
    require(l1_crypto_candidate_entry(2, argv2, [&] {
              ++invoked;
              return 0;
            }) == 10,
            "candidate entry denies with exit 10");
    require(invoked == 0, "candidate entry never invokes callback");
  }
  const wchar_t* argv1[] = {prog};
  unsigned invoked = 0;
  require(l1_crypto_candidate_entry(1, argv1, [&] {
            ++invoked;
            return 0;
          }) == 10,
          "candidate entry 1-arg denies with exit 10");
  require(invoked == 0, "candidate entry 1-arg zero invocations");

  const wchar_t* empty_arg[] = {prog, L""};
  require(l1_crypto_candidate_entry(2, empty_arg, [&] { return 0; }) == 64,
          "empty mode argument rejected with 64");
}

}  // namespace

int main() {
  test_normal_sequence_and_redaction();
  test_first_failure_stops_immediately();
  test_budget_exhaustion_and_failed_call_consumption();
  test_expected_rejection_vs_unexpected_outcomes();
  test_der_raw_signature_boundary_and_certificate_roles();
  test_buffer_single_release_and_unknown_state();
  test_resource_sampling_and_timeout_gates();
  test_forbidden_symbols_and_default_deny_entry();
  std::cout << "PASS: fake-only L1-CRYPTO harness ledger (3/3/6/3), "
               "7-symbol allowlist, DER/raw boundary, single release, "
               "sampling/30s gates and default-deny entry (no real CNG/crypt32)\n";
  return 0;
}
