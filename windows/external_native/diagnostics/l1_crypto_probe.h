#ifndef SHIROHA_L1_CRYPTO_PROBE_H_
#define SHIROHA_L1_CRYPTO_PROBE_H_

#include <windows.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "diagnostics/l1_native_observation.h"
#include "shiroha_external_native.h"

// G0-L0 source/offline harness candidate for future L1-CRYPTO only.
// Real execution remains blocked by default in l1_crypto_candidate_entry.
namespace shiroha_l1_crypto {

using abi_fn = uint32_t(SHIROHA_NATIVE_CALL*)(void);
using alloc_fn = uint8_t*(SHIROHA_NATIVE_CALL*)(uint64_t);
using free_fn = void(SHIROHA_NATIVE_CALL*)(uint8_t*);
using generate_key_fn = int32_t(SHIROHA_NATIVE_CALL*)(
    uint32_t, uint8_t*, uint64_t, uint64_t*, uint8_t*, uint64_t, uint64_t*);
using sign_digest_fn = int32_t(SHIROHA_NATIVE_CALL*)(
    uint32_t, const uint8_t*, uint64_t, const uint8_t*, uint64_t,
    const uint8_t*, uint64_t, uint8_t*, uint64_t, uint64_t*);
using verify_digest_fn = int32_t(SHIROHA_NATIVE_CALL*)(
    uint32_t, const uint8_t*, uint64_t, const uint8_t*, uint64_t,
    const uint8_t*, uint64_t);
using peer_policy_fn = int32_t(SHIROHA_NATIVE_CALL*)(
    uint32_t, const uint8_t*, uint64_t, uint32_t);

inline constexpr std::array<const char*, 7> kAllowedSymbols = {
    "shiroha_native_abi_version",
    "shiroha_native_buffer_alloc",
    "shiroha_native_buffer_free",
    "shiroha_native_ecdsa_generate_key",
    "shiroha_native_ecdsa_sign_digest",
    "shiroha_native_ecdsa_verify_digest",
    "shiroha_native_peer_certificate_policy",
};

inline constexpr std::array<const char*, 20> kForbiddenSymbols = {
    "shiroha_native_local_app_data",
    "shiroha_native_dpapi_protect",
    "shiroha_native_dpapi_unprotect",
    "shiroha_native_owner_acquire",
    "shiroha_native_owner_validate",
    "shiroha_native_owner_close",
    "shiroha_native_association_begin",
    "shiroha_native_association_commit",
    "shiroha_native_association_abort",
    "shiroha_native_credential_begin",
    "shiroha_native_credential_commit",
    "shiroha_native_credential_abort",
    "shiroha_native_exchange_create",
    "shiroha_native_exchange_read",
    "shiroha_native_exchange_cleanup",
    "shiroha_native_exchange_read_begin",
    "shiroha_native_exchange_consume",
    "shiroha_native_exchange_release",
    "shiroha_native_discovery_publish",
    "shiroha_native_discovery_read",
};

inline bool is_allowed_l1_crypto_symbol(const char* name) noexcept {
  if (!name || *name == '\0') return false;
  for (const char* allowed : kAllowedSymbols) {
    if (std::strcmp(name, allowed) == 0) return true;
  }
  return false;
}

inline bool is_forbidden_abi_symbol(const char* name) noexcept {
  if (!name || *name == '\0') return true;
  for (const char* forbidden : kForbiddenSymbols) {
    if (std::strcmp(name, forbidden) == 0) return true;
  }
  return !is_allowed_l1_crypto_symbol(name);
}

struct L1CryptoApi {
  abi_fn abi = nullptr;
  alloc_fn allocate = nullptr;
  free_fn deallocate = nullptr;
  generate_key_fn generate_key = nullptr;
  sign_digest_fn sign_digest = nullptr;
  verify_digest_fn verify_digest = nullptr;
  peer_policy_fn peer_certificate_policy = nullptr;
};

enum class PrimitiveCategory {
  kAbi,
  kGenerateKey,
  kCertificateEncodeSign,
  kVerifyPositive,
  kVerifyNegative,
  kPeerPolicyPositive,
  kPeerPolicyNegative,
};

struct L1CryptoLedger {
  static constexpr unsigned kMaxAbiCalls = 1;
  static constexpr unsigned kMaxKeyGenerations = 3;
  static constexpr unsigned kMaxCertificateEncodeSigns = 3;
  static constexpr unsigned kMaxVerifyCalls = 6;
  static constexpr unsigned kMaxVerifyPositiveCalls = 3;
  static constexpr unsigned kMaxVerifyNegativeCalls = 3;
  static constexpr unsigned kMaxPeerPolicyCalls = 3;
  static constexpr unsigned kMaxAllocationAttempts = 45;
  static constexpr unsigned kMaxFreeAttempts = 45;
  static constexpr unsigned kMaxLiveBuffers = 5;
  static constexpr unsigned kMaxTotalAbiAttempts = 106;
  static constexpr uint64_t kCandidateMaxElapsedMs = 30000;
  static constexpr unsigned kTotalPlannedSteps = 16;

  static constexpr std::array<const char*, kTotalPlannedSteps> kSteps = {
      "abi",
      "gen_issuer",
      "gen_server",
      "gen_client",
      "sign_issuer_cert",
      "sign_server_cert",
      "sign_client_cert",
      "verify_issuer_valid",
      "verify_server_valid",
      "verify_client_valid",
      "verify_issuer_tampered",
      "verify_server_tampered",
      "verify_client_tampered",
      "policy_server_valid",
      "policy_client_valid",
      "policy_role_mismatch",
  };

  uint32_t attempted_steps = 0;
  uint32_t returned_steps = 0;
  uint32_t completed_steps = 0;

  unsigned attempted = 0;
  unsigned returned = 0;
  unsigned completed = 0;
  unsigned successful = 0;
  unsigned accepted = 0;

  unsigned abi_reserved = 0;
  unsigned generate_reserved = 0;
  unsigned encode_sign_reserved = 0;
  unsigned verify_reserved = 0;
  unsigned verify_positive_reserved = 0;
  unsigned verify_negative_reserved = 0;
  unsigned policy_reserved = 0;
  unsigned budget_rejections = 0;
  // ABI, generate, encode/sign, verify, policy, allocation, free. Counts are
  // cumulative, including failed/null/throwing attempts; slots never refill
  // them.
  std::array<CallCounts, 7> abi_calls{};
  unsigned abi_attempted_total = 0;
  NativeObservation* native_observation = nullptr;

  bool reserve_abi(size_t index, unsigned limit) noexcept {
    if (abi_attempted_total >= kMaxTotalAbiAttempts ||
        abi_calls[index].attempted >= limit) {
      ++budget_rejections;
      stop("abi_call_budget_exceeded", -1, "BUDGET_EXCEEDED");
      return false;
    }
    ++abi_calls[index].attempted;
    ++abi_attempted_total;
    return true;
  }

  unsigned allowed_symbol_resolutions = 0;
  unsigned forbidden_symbol_attempts = 0;

  unsigned buffers_allocated = 0;
  unsigned buffers_live = 0;
  unsigned releases_attempted = 0;
  unsigned releases_succeeded = 0;
  unsigned releases_unknown = 0;
  unsigned duplicate_release_attempts = 0;

  unsigned observation_attempts = 0;
  unsigned observation_failures = 0;
  unsigned samples = 0;
  uint64_t peak_working_set = 0;
  uint64_t peak_commit = 0;
  uint32_t handles_first = 0;
  uint32_t handles_last = 0;
  uint32_t handles_max_sampled = 0;

  // Optional configured ceilings; 0 means unbounded in synthetic unit tests,
  // while real admission requires explicit user-approved ceilings.
  uint64_t working_set_limit_bytes = 0;
  uint64_t commit_limit_bytes = 0;
  uint32_t handle_limit = 0;
  uint64_t max_elapsed_ms = kCandidateMaxElapsedMs;

  bool (*sample)(L1CryptoLedger&) noexcept = nullptr;
  bool (*clock_ms)(uint64_t& out_ms) noexcept = nullptr;

  bool clock_initialized = false;
  uint64_t start_ms = 0;
  uint64_t last_ms = 0;
  uint64_t elapsed_ms = 0;

  bool stopped = false;
  bool settlement_unknown = false;
  const char* first_failure = "none";
  const char* failure_code = "NONE";
  int first_status = 0;

  void stop(const char* step, int status, const char* code) noexcept {
    if (!stopped) {
      first_failure = step ? step : "unknown";
      first_status = status;
      failure_code = code ? code : "ADMISSION_BLOCKED";
    }
    if (code && std::strcmp(code, "SETTLEMENT_UNKNOWN") == 0) {
      settlement_unknown = true;
    }
    stopped = true;
  }

  bool check_clock(const char* step) noexcept {
    if (!clock_ms) return !stopped;
    uint64_t now = 0;
    if (!clock_ms(now)) {
      stop(step, -1, "MEASUREMENT_UNAVAILABLE");
      return false;
    }
    if (!clock_initialized) {
      clock_initialized = true;
      start_ms = now;
      last_ms = now;
      elapsed_ms = 0;
      return true;
    }
    if (now < last_ms) {
      stop(step, -1, "MEASUREMENT_UNAVAILABLE");
      return false;
    }
    last_ms = now;
    elapsed_ms = now - start_ms;
    if (elapsed_ms > max_elapsed_ms) {
      stop("deadline_exceeded", -1, "BUDGET_EXCEEDED");
      return false;
    }
    return !stopped;
  }

  bool resources(uint64_t working, uint64_t commit, uint32_t handles) noexcept {
    if (working == 0 || commit == 0 || handles == 0) {
      stop("resource_observation_invalid", -1, "MEASUREMENT_UNAVAILABLE");
      return false;
    }
    if (working > peak_working_set) peak_working_set = working;
    if (commit > peak_commit) peak_commit = commit;
    if (samples++ == 0) handles_first = handles;
    handles_last = handles;
    if (handles > handles_max_sampled) handles_max_sampled = handles;
    if ((working_set_limit_bytes > 0 && working > working_set_limit_bytes) ||
        (commit_limit_bytes > 0 && commit > commit_limit_bytes) ||
        (handle_limit > 0 && handles > handle_limit)) {
      stop("resource_budget_exceeded", -1, "BUDGET_EXCEEDED");
      return false;
    }
    return true;
  }

  bool observe(const char* stage) noexcept {
    if (!check_clock(stage)) return false;
    ++observation_attempts;
    if (!sample || !sample(*this)) {
      ++observation_failures;
      if (std::strcmp(failure_code, "BUDGET_EXCEEDED") != 0) {
        stop("resource_observation_failed", -1, "MEASUREMENT_UNAVAILABLE");
      }
      return false;
    }
    return !stopped;
  }

  static int step_index(const char* step) noexcept {
    if (!step) return -1;
    for (unsigned i = 0; i < kTotalPlannedSteps; ++i) {
      if (std::strcmp(step, kSteps[i]) == 0) return static_cast<int>(i);
    }
    return -1;
  }

  bool reserve_category(PrimitiveCategory cat) noexcept {
    switch (cat) {
      case PrimitiveCategory::kAbi:
        if (abi_reserved >= kMaxAbiCalls) return false;
        ++abi_reserved;
        return true;
      case PrimitiveCategory::kGenerateKey:
        if (generate_reserved >= kMaxKeyGenerations) return false;
        ++generate_reserved;
        return true;
      case PrimitiveCategory::kCertificateEncodeSign:
        if (encode_sign_reserved >= kMaxCertificateEncodeSigns) return false;
        ++encode_sign_reserved;
        return true;
      case PrimitiveCategory::kVerifyPositive:
        if (verify_reserved >= kMaxVerifyCalls ||
            verify_positive_reserved >= kMaxVerifyPositiveCalls) {
          return false;
        }
        ++verify_reserved;
        ++verify_positive_reserved;
        return true;
      case PrimitiveCategory::kVerifyNegative:
        if (verify_reserved >= kMaxVerifyCalls ||
            verify_negative_reserved >= kMaxVerifyNegativeCalls) {
          return false;
        }
        ++verify_reserved;
        ++verify_negative_reserved;
        return true;
      case PrimitiveCategory::kPeerPolicyPositive:
      case PrimitiveCategory::kPeerPolicyNegative:
        if (policy_reserved >= kMaxPeerPolicyCalls) return false;
        ++policy_reserved;
        return true;
    }
    return false;
  }

  template <typename Call, typename ShapeCheck>
  bool invoke_and_check(PrimitiveCategory cat, const char* step,
                        int expected_status, Call&& call,
                        ShapeCheck&& shape_ok) noexcept {
    if (stopped) return false;
    if (!check_clock(step)) return false;
    if (!reserve_category(cat)) {
      ++budget_rejections;
      stop("call_budget_exceeded", -1, "BUDGET_EXCEEDED");
      return false;
    }
    const size_t category = cat == PrimitiveCategory::kAbi           ? 0
                            : cat == PrimitiveCategory::kGenerateKey ? 1
                            : cat == PrimitiveCategory::kCertificateEncodeSign
                                ? 2
                            : (cat == PrimitiveCategory::kVerifyPositive ||
                               cat == PrimitiveCategory::kVerifyNegative)
                                ? 3
                                : 4;
    constexpr unsigned limits[] = {1, 3, 3, 6, 3};
    if (!reserve_abi(category, limits[category])) return false;
    auto& counts = abi_calls[category];
    const int idx = step_index(step);
    if (idx >= 0) attempted_steps |= (1u << static_cast<unsigned>(idx));
    ++attempted;
    int status = -1;
    try {
      status = static_cast<int>(call());
    } catch (...) {
      ++counts.unknown;
      stop(step, -1, "SETTLEMENT_UNKNOWN");
      observe(step);
      return false;
    }
    ++returned;
    ++counts.returned;
    if (!native_observation || !native_observation->unknown)
      ++counts.settled;
    else
      ++counts.unknown;
    if (idx >= 0) returned_steps |= (1u << static_cast<unsigned>(idx));
    if (!check_clock(step)) {
      observe(step);
      return false;
    }
    const bool shape_valid = shape_ok(status);
    ++completed;
    if (idx >= 0) completed_steps |= (1u << static_cast<unsigned>(idx));
    if (cat == PrimitiveCategory::kAbi
            ? (status == expected_status)
            : (status == SHIROHA_NATIVE_OK)) {
      ++successful;
    }
    const bool is_negative_case =
        (cat == PrimitiveCategory::kVerifyNegative ||
         cat == PrimitiveCategory::kPeerPolicyNegative);
    if (native_observation && native_observation->stopped) {
      stop(native_observation->first_failure, status,
           native_observation->first_failure_unknown ? "SETTLEMENT_UNKNOWN"
                                                     : "ADMISSION_BLOCKED");
      settlement_unknown = settlement_unknown || native_observation->unknown;
    } else if (status == expected_status && shape_valid) {
      ++accepted;
      ++counts.accepted;
    } else if (is_negative_case && status == SHIROHA_NATIVE_OK) {
      stop(step, status, "SECURITY_REJECT_MISMATCH");
    } else if (!is_negative_case &&
               status == SHIROHA_NATIVE_VERIFICATION_REJECTED) {
      stop(step, status, "SECURITY_REJECT_MISMATCH");
    } else {
      stop(step, status, "ADMISSION_BLOCKED");
    }
    return observe(step);
  }

  const char* verdict() const noexcept {
    if (settlement_unknown || releases_unknown > 0 || returned < attempted ||
        (native_observation && native_observation->unknown)) {
      return "UNKNOWN";
    }
    if (observation_failures > 0 || samples < kTotalPlannedSteps + 2) {
      if (std::strcmp(failure_code, "MEASUREMENT_UNAVAILABLE") == 0) {
        return "INCONCLUSIVE";
      }
    }
    if (stopped || accepted != kTotalPlannedSteps ||
        completed != kTotalPlannedSteps || buffers_live != 0 ||
        duplicate_release_attempts != 0 || forbidden_symbol_attempts != 0) {
      return "FAIL";
    }
    if (abi_attempted_total != kMaxTotalAbiAttempts ||
        (native_observation && !native_observation->complete()))
      return "FAIL";
    return "PASS";
  }

  std::string format_redacted_summary() const {
    char line[1024]{};
    std::snprintf(
        line, sizeof(line),
        "summary testId=L1-CRYPTO evidenceClass=OFFLINE verdict=%s "
        "failureCode=%s firstFailure=%s firstStatus=%d stopped=%d "
        "attempted=%u returned=%u completed=%u successful=%u accepted=%u "
        "abi=%u generate=%u encodeSign=%u verify=%u(pos=%u,neg=%u) policy=%u "
        "budgetRejections=%u allowedSymbols=%u forbiddenSymbols=%u "
        "buffersAllocated=%u buffersLive=%u releasesAttempted=%u "
        "releasesSucceeded=%u releasesUnknown=%u duplicateReleases=%u "
        "observations=%u observationFailures=%u samples=%u "
        "peakWorkingSetBytes=%llu peakCommitBytes=%llu "
        "handlesFirst=%u handlesLast=%u handlesMaxSampled=%u "
        "elapsedMilliseconds=%llu\n",
        verdict(), failure_code, first_failure, first_status, stopped ? 1 : 0,
        attempted, returned, completed, successful, accepted, abi_reserved,
        generate_reserved, encode_sign_reserved, verify_reserved,
        verify_positive_reserved, verify_negative_reserved, policy_reserved,
        budget_rejections, allowed_symbol_resolutions,
        forbidden_symbol_attempts, buffers_allocated, buffers_live,
        releases_attempted, releases_succeeded, releases_unknown,
        duplicate_release_attempts, observation_attempts, observation_failures,
        samples, static_cast<unsigned long long>(peak_working_set),
        static_cast<unsigned long long>(peak_commit), handles_first,
        handles_last, handles_max_sampled,
        static_cast<unsigned long long>(elapsed_ms));
    std::string out(line);
    constexpr std::array<const char*, 7> categories = {
        "abi",    "generate",   "encodeSign", "verify",
        "policy", "allocation", "free"};
    for (size_t i = 0; i < abi_calls.size(); ++i) {
      const auto& c = abi_calls[i];
      std::snprintf(line, sizeof(line),
                    "abi_category=%s attempted=%u returned=%u accepted=%u "
                    "settled=%u unknown=%u\n",
                    categories[i], c.attempted, c.returned, c.accepted,
                    c.settled, c.unknown);
      out += line;
    }
    if (native_observation) {
      for (size_t i = 0; i < kNativeOpCount; ++i) {
        const auto& c = native_observation->calls[i];
        std::snprintf(line, sizeof(line),
                      "native_category=%s attempted=%u returned=%u accepted=%u "
                      "settled=%u unknown=%u returnedFailure=%u\n",
                      kNativeNames[i], c.attempted, c.returned, c.accepted,
                      c.settled, c.unknown, c.returned_failure);
        out += line;
      }
      std::snprintf(line, sizeof(line),
                    "native_resources acquired=%u released=%u stillOwned=%u "
                    "quarantined=%u\n",
                    native_observation->acquired, native_observation->released,
                    native_observation->still_owned,
                    native_observation->quarantined);
      out += line;
    }
    for (unsigned i = 0; i < kTotalPlannedSteps; ++i) {
      if (!(attempted_steps & (1u << i))) {
        out += "not_executed step=";
        out += kSteps[i];
        out += "\n";
      } else if (!(completed_steps & (1u << i))) {
        out += "not_completed step=";
        out += kSteps[i];
        out += (returned_steps & (1u << i)) ? " returned=1\n" : " returned=0\n";
      }
    }
    return out;
  }
};

template <typename Lookup, typename FnPtr>
bool resolve_symbol_checked(L1CryptoLedger& ledger, const char* name,
                            Lookup&& lookup, FnPtr& target) noexcept {
  target = nullptr;
  if (!is_allowed_l1_crypto_symbol(name)) {
    ++ledger.forbidden_symbol_attempts;
    ledger.stop("forbidden_symbol_resolution", -1, "UNAUTHORIZED_ACCESS");
    return false;
  }
  void* raw = nullptr;
  try {
    raw = lookup(name);
  } catch (...) {
    ledger.stop("symbol_lookup_exception", -1, "ARTIFACT_INVALID");
    return false;
  }
  if (!raw) {
    ledger.stop("missing_allowed_symbol", -1, "ARTIFACT_INVALID");
    return false;
  }
  static_assert(sizeof(FnPtr) == sizeof(raw), "Windows x64 function pointer");
  std::memcpy(&target, &raw, sizeof(target));
  ++ledger.allowed_symbol_resolutions;
  return true;
}

template <typename Lookup>
bool resolve_l1_crypto_api(L1CryptoLedger& ledger, Lookup&& lookup,
                           L1CryptoApi& api) noexcept {
  api = L1CryptoApi{};
  return resolve_symbol_checked(ledger, "shiroha_native_abi_version", lookup,
                                api.abi) &&
         resolve_symbol_checked(ledger, "shiroha_native_buffer_alloc", lookup,
                                api.allocate) &&
         resolve_symbol_checked(ledger, "shiroha_native_buffer_free", lookup,
                                api.deallocate) &&
         resolve_symbol_checked(ledger, "shiroha_native_ecdsa_generate_key",
                                lookup, api.generate_key) &&
         resolve_symbol_checked(ledger, "shiroha_native_ecdsa_sign_digest",
                                lookup, api.sign_digest) &&
         resolve_symbol_checked(ledger, "shiroha_native_ecdsa_verify_digest",
                                lookup, api.verify_digest) &&
         resolve_symbol_checked(ledger,
                                "shiroha_native_peer_certificate_policy",
                                lookup, api.peer_certificate_policy);
}

class L1CryptoBufferPool {
 public:
  static constexpr size_t kMaxSlots = 64;
  struct Slot {
    uint8_t* ptr = nullptr;
    size_t capacity = 0;
    bool allocated_ever = false;
    bool active = false;
    bool release_attempted = false;
    bool release_succeeded = false;
    bool release_unknown = false;
  };

  L1CryptoBufferPool(const L1CryptoApi& api, L1CryptoLedger& ledger) noexcept
      : api_(api), ledger_(ledger) {}

  ~L1CryptoBufferPool() noexcept { release_all_remaining(); }

  L1CryptoBufferPool(const L1CryptoBufferPool&) = delete;
  L1CryptoBufferPool& operator=(const L1CryptoBufferPool&) = delete;

  bool allocate(size_t capacity, uint8_t** out_ptr,
                size_t* out_slot) noexcept {
    if (out_ptr) *out_ptr = nullptr;
    if (out_slot) *out_slot = kMaxSlots;
    if (ledger_.stopped || !out_ptr || !out_slot || capacity == 0 ||
        capacity > SHIROHA_NATIVE_MAX_BYTES || used_ >= kMaxSlots ||
        ledger_.buffers_live >= L1CryptoLedger::kMaxLiveBuffers ||
        !api_.allocate) {
      ledger_.stop("buffer_alloc_precondition", -1, "BUDGET_EXCEEDED");
      return false;
    }
    if (!ledger_.check_clock("buffer_alloc") ||
        !ledger_.reserve_abi(5, L1CryptoLedger::kMaxAllocationAttempts))
      return false;
    auto& counts = ledger_.abi_calls[5];
    uint8_t* mem = nullptr;
    try {
      mem = api_.allocate(static_cast<uint64_t>(capacity));
    } catch (...) {
      ++counts.unknown;
      ledger_.stop("buffer_alloc_exception", -1, "SETTLEMENT_UNKNOWN");
      return false;
    }
    ++counts.returned;
    ++counts.settled;
    if (!mem) {
      ++counts.returned_failure;
      ledger_.stop("buffer_alloc_null", SHIROHA_NATIVE_RESOURCE_LIMIT,
                   "BUDGET_EXCEEDED");
      return false;
    }
    ++counts.accepted;
    SecureZeroMemory(mem, capacity);
    const size_t idx = used_++;
    slots_[idx] = Slot{mem, capacity, true, true, false, false, false};
    ++ledger_.buffers_allocated;
    ++ledger_.buffers_live;
    *out_ptr = mem;
    *out_slot = idx;
    return true;
  }

  bool release(size_t slot_index) noexcept {
    if (slot_index >= used_ || !slots_[slot_index].allocated_ever) {
      ledger_.stop("unknown_buffer_slot", -1, "OWNERSHIP_UNKNOWN");
      return false;
    }
    Slot& slot = slots_[slot_index];
    if (slot.release_attempted) {
      ++ledger_.duplicate_release_attempts;
      ledger_.stop("duplicate_buffer_release", -1, "OWNERSHIP_UNKNOWN");
      return false;
    }
    slot.release_attempted = true;
    if (!ledger_.reserve_abi(6, L1CryptoLedger::kMaxFreeAttempts)) {
      slot.release_unknown = true;
      ++ledger_.releases_unknown;
      ledger_.stop("free_budget_unsettled", -1, "SETTLEMENT_UNKNOWN");
      return false;
    }
    auto& counts = ledger_.abi_calls[6];
    ++ledger_.releases_attempted;
    try {
      SecureZeroMemory(slot.ptr, slot.capacity);
      if (!api_.deallocate) {
        throw 1;
      }
      api_.deallocate(slot.ptr);
      ++counts.returned;
      ++counts.accepted;
      ++counts.settled;
      slot.ptr = nullptr;
      slot.active = false;
      slot.release_succeeded = true;
      ++ledger_.releases_succeeded;
      if (ledger_.buffers_live > 0) --ledger_.buffers_live;
      return true;
    } catch (...) {
      ++counts.unknown;
      slot.release_unknown = true;
      ++ledger_.releases_unknown;
      ledger_.stop("buffer_release_unknown", -1, "SETTLEMENT_UNKNOWN");
      return false;
    }
  }

  void release_all_remaining() noexcept {
    for (size_t i = used_; i > 0; --i) {
      const size_t idx = i - 1;
      if (slots_[idx].allocated_ever && !slots_[idx].release_attempted) {
        release(idx);
      }
    }
  }

 private:
  const L1CryptoApi& api_;
  L1CryptoLedger& ledger_;
  std::array<Slot, kMaxSlots> slots_{};
  size_t used_ = 0;
};

struct EphemeralKeySlot {
  std::array<uint8_t, SHIROHA_NATIVE_ECDSA_PKCS8_MAX> pkcs8{};
  size_t pkcs8_len = 0;
  std::array<uint8_t, SHIROHA_NATIVE_ECDSA_POINT_BYTES> point{};
  bool private_wiped = false;

  void wipe_private() noexcept {
    SecureZeroMemory(pkcs8.data(), pkcs8.size());
    pkcs8_len = 0;
    private_wiped = true;
  }

  ~EphemeralKeySlot() noexcept {
    wipe_private();
    SecureZeroMemory(point.data(), point.size());
  }
};

// Minimal FIPS 180-4 SHA-256 for deterministic in-memory TBS digesting.
inline void sha256_digest(const uint8_t* data, size_t len,
                          uint8_t out[32]) noexcept {
  static constexpr uint32_t k[64] = {
      0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
      0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
      0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
      0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
      0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
      0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
      0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcU,
      0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
      0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
      0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
      0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
      0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
      0x90befffaU, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
  auto rotr = [](uint32_t x, unsigned n) noexcept -> uint32_t {
    return (x >> n) | (x << (32u - n));
  };
  uint32_t h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                   0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
  const size_t total_len = ((len + 9 + 63) / 64) * 64;
  std::vector<uint8_t> padded(total_len, 0);
  if (len > 0) std::memcpy(padded.data(), data, len);
  padded[len] = 0x80;
  const uint64_t bit_len = static_cast<uint64_t>(len) * 8ull;
  for (size_t i = 0; i < 8; ++i) {
    padded[total_len - 1 - i] =
        static_cast<uint8_t>((bit_len >> (i * 8)) & 0xffu);
  }
  for (size_t chunk = 0; chunk < total_len; chunk += 64) {
    uint32_t w[64]{};
    for (size_t i = 0; i < 16; ++i) {
      const uint8_t* p = padded.data() + chunk + i * 4;
      w[i] = (static_cast<uint32_t>(p[0]) << 24) |
             (static_cast<uint32_t>(p[1]) << 16) |
             (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
    }
    for (size_t i = 16; i < 64; ++i) {
      const uint32_t s0 =
          rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 =
          rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5],
             g = h[6], hh = h[7];
    for (size_t i = 0; i < 64; ++i) {
      const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const uint32_t ch = (e & f) ^ ((~e) & g);
      const uint32_t temp1 = hh + s1 + ch + k[i] + w[i];
      const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t temp2 = s0 + maj;
      hh = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }
  for (size_t i = 0; i < 8; ++i) {
    out[i * 4] = static_cast<uint8_t>((h[i] >> 24) & 0xffu);
    out[i * 4 + 1] = static_cast<uint8_t>((h[i] >> 16) & 0xffu);
    out[i * 4 + 2] = static_cast<uint8_t>((h[i] >> 8) & 0xffu);
    out[i * 4 + 3] = static_cast<uint8_t>(h[i] & 0xffu);
  }
}

inline constexpr uint8_t kP256Order[32] = {
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17,
    0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51};

inline bool scalar_in_range(const uint8_t s[32]) noexcept {
  bool nonzero = false;
  for (size_t i = 0; i < 32; ++i) nonzero = nonzero || (s[i] != 0);
  return nonzero && std::memcmp(s, kP256Order, 32) < 0;
}

inline std::vector<uint8_t> der_wrap(uint8_t tag,
                                     const std::vector<uint8_t>& body) {
  std::vector<uint8_t> out;
  out.push_back(tag);
  const size_t n = body.size();
  if (n < 128) {
    out.push_back(static_cast<uint8_t>(n));
  } else if (n < 256) {
    out.push_back(0x81);
    out.push_back(static_cast<uint8_t>(n));
  } else {
    out.push_back(0x82);
    out.push_back(static_cast<uint8_t>((n >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>(n & 0xffu));
  }
  out.insert(out.end(), body.begin(), body.end());
  return out;
}

inline bool raw_signature_to_der(const uint8_t* raw, size_t raw_len,
                                 std::vector<uint8_t>& der_out) {
  der_out.clear();
  if (!raw || raw_len != 64 || !scalar_in_range(raw) ||
      !scalar_in_range(raw + 32)) {
    return false;
  }
  auto encode_int = [](const uint8_t scalar[32]) -> std::vector<uint8_t> {
    size_t start = 0;
    while (start < 31 && scalar[start] == 0) ++start;
    std::vector<uint8_t> body;
    if ((scalar[start] & 0x80u) != 0) body.push_back(0x00);
    body.insert(body.end(), scalar + start, scalar + 32);
    return der_wrap(0x02, body);
  };
  std::vector<uint8_t> seq = encode_int(raw);
  const std::vector<uint8_t> s_int = encode_int(raw + 32);
  seq.insert(seq.end(), s_int.begin(), s_int.end());
  der_out = der_wrap(0x30, seq);
  return true;
}

inline bool der_signature_to_raw(const uint8_t* der, size_t der_len,
                                 uint8_t raw_out[64]) noexcept {
  if (!der || der_len < 8 || der_len > 72 || !raw_out) return false;
  SecureZeroMemory(raw_out, 64);
  if (der[0] != 0x30) return false;
  const size_t seq_len = der[1];
  if ((seq_len & 0x80u) != 0 || 2 + seq_len != der_len) return false;
  size_t offset = 2;
  for (int part = 0; part < 2; ++part) {
    if (offset + 2 > der_len || der[offset] != 0x02) return false;
    const size_t int_len = der[offset + 1];
    offset += 2;
    if (int_len == 0 || int_len > 33 || offset + int_len > der_len) {
      return false;
    }
    const uint8_t* bytes = der + offset;
    if ((bytes[0] & 0x80u) != 0) return false;
    if (int_len > 1 && bytes[0] == 0 && (bytes[1] & 0x80u) == 0) return false;
    const uint8_t* mag = (int_len > 1 && bytes[0] == 0) ? bytes + 1 : bytes;
    const size_t mag_len =
        (int_len > 1 && bytes[0] == 0) ? int_len - 1 : int_len;
    if (mag_len == 0 || mag_len > 32) return false;
    uint8_t scalar[32]{};
    std::memcpy(scalar + (32 - mag_len), mag, mag_len);
    if (!scalar_in_range(scalar)) {
      SecureZeroMemory(raw_out, 64);
      return false;
    }
    std::memcpy(raw_out + part * 32, scalar, 32);
    offset += int_len;
  }
  if (offset != der_len) {
    SecureZeroMemory(raw_out, 64);
    return false;
  }
  return true;
}

enum class CertificateRole : uint32_t { kIssuer = 0, kServer = 1, kClient = 2 };

inline bool build_x509_tbs(CertificateRole role, const uint8_t serial16[16],
                           const uint8_t public_point[65],
                           std::vector<uint8_t>& tbs_out) {
  tbs_out.clear();
  if (!serial16 || !public_point || public_point[0] != 0x04) return false;
  bool serial_nonzero = false;
  for (size_t i = 0; i < 16; ++i) {
    if (serial16[i] != 0) serial_nonzero = true;
  }
  if (!serial_nonzero) return false;

  size_t s_start = 0;
  while (s_start < 15 && serial16[s_start] == 0) ++s_start;
  std::vector<uint8_t> serial_body;
  if ((serial16[s_start] & 0x80u) != 0) serial_body.push_back(0x00);
  serial_body.insert(serial_body.end(), serial16 + s_start, serial16 + 16);

  const std::vector<uint8_t> version =
      der_wrap(0xa0, der_wrap(0x02, {0x02}));
  const std::vector<uint8_t> serial = der_wrap(0x02, serial_body);
  const std::vector<uint8_t> sig_alg = der_wrap(
      0x30, der_wrap(0x06, {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02}));

  auto make_name = [](const char* cn) -> std::vector<uint8_t> {
    const size_t n = std::strlen(cn);
    std::vector<uint8_t> cn_bytes(cn, cn + n);
    std::vector<uint8_t> attr = der_wrap(0x06, {0x55, 0x04, 0x03});
    const std::vector<uint8_t> val = der_wrap(0x0c, cn_bytes);
    attr.insert(attr.end(), val.begin(), val.end());
    return der_wrap(0x30, der_wrap(0x31, der_wrap(0x30, attr)));
  };
  const std::vector<uint8_t> issuer_name =
      make_name("Shiroha External Installation Issuer");
  const std::vector<uint8_t> subject_name =
      role == CertificateRole::kIssuer
          ? issuer_name
          : (role == CertificateRole::kServer
                 ? make_name("Shiroha External Host")
                 : make_name("Shiroha External Bridge"));

  // Validity covers 2025-01-01T00:00:00Z .. 2035-01-01T00:00:00Z (issuer)
  // or 2027-01-01T00:00:00Z (leaf) so crypt32 CertVerifyTimeValidity(nullptr)
  // succeeds on the current host date while keeping leaf within issuer bounds.
  const char* not_before_str = "250101000000Z";
  const char* not_after_str =
      role == CertificateRole::kIssuer ? "350101000000Z" : "270101000000Z";
  std::vector<uint8_t> validity_body = der_wrap(
      0x17, std::vector<uint8_t>(not_before_str, not_before_str + 13));
  const std::vector<uint8_t> after_der = der_wrap(
      0x17, std::vector<uint8_t>(not_after_str, not_after_str + 13));
  validity_body.insert(validity_body.end(), after_der.begin(), after_der.end());
  const std::vector<uint8_t> validity = der_wrap(0x30, validity_body);

  std::vector<uint8_t> spki_alg_body =
      der_wrap(0x06, {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01});
  const std::vector<uint8_t> curve_oid =
      der_wrap(0x06, {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07});
  spki_alg_body.insert(spki_alg_body.end(), curve_oid.begin(), curve_oid.end());
  std::vector<uint8_t> point_bits = {0x00};
  point_bits.insert(point_bits.end(), public_point, public_point + 65);
  std::vector<uint8_t> spki_body = der_wrap(0x30, spki_alg_body);
  const std::vector<uint8_t> spki_bitstr = der_wrap(0x03, point_bits);
  spki_body.insert(spki_body.end(), spki_bitstr.begin(), spki_bitstr.end());
  const std::vector<uint8_t> spki = der_wrap(0x30, spki_body);

  auto make_ext = [](const std::vector<uint8_t>& oid, bool critical,
                     const std::vector<uint8_t>& val) -> std::vector<uint8_t> {
    std::vector<uint8_t> seq = der_wrap(0x06, oid);
    if (critical) {
      const std::vector<uint8_t> crit = {0x01, 0x01, 0xff};
      seq.insert(seq.end(), crit.begin(), crit.end());
    }
    const std::vector<uint8_t> octets = der_wrap(0x04, val);
    seq.insert(seq.end(), octets.begin(), octets.end());
    return der_wrap(0x30, seq);
  };

  const bool is_issuer = (role == CertificateRole::kIssuer);
  std::vector<uint8_t> exts = make_ext(
      {0x55, 0x1d, 0x13}, true,
      der_wrap(0x30,
               is_issuer ? std::vector<uint8_t>{0x01, 0x01, 0xff, 0x02, 0x01, 0x00}
                         : std::vector<uint8_t>{}));
  const std::vector<uint8_t> ku = make_ext(
      {0x55, 0x1d, 0x0f}, true,
      der_wrap(0x03, is_issuer ? std::vector<uint8_t>{0x02, 0x04}
                               : std::vector<uint8_t>{0x07, 0x80}));
  exts.insert(exts.end(), ku.begin(), ku.end());
  if (!is_issuer) {
    const uint8_t eku_last = (role == CertificateRole::kServer) ? 0x01 : 0x02;
    const std::vector<uint8_t> eku = make_ext(
        {0x55, 0x1d, 0x25}, false,
        der_wrap(0x30, der_wrap(0x06, {0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03,
                                       eku_last})));
    exts.insert(exts.end(), eku.begin(), eku.end());
  }
  if (role == CertificateRole::kServer) {
    const std::vector<uint8_t> san =
        make_ext({0x55, 0x1d, 0x11}, true,
                 der_wrap(0x30, {0x87, 0x04, 127, 0, 0, 1}));
    exts.insert(exts.end(), san.begin(), san.end());
  }
  const std::vector<uint8_t> extensions = der_wrap(0xa3, der_wrap(0x30, exts));

  std::vector<uint8_t> tbs_body;
  for (const auto& part : {version, serial, sig_alg, issuer_name, validity,
                           subject_name, spki, extensions}) {
    tbs_body.insert(tbs_body.end(), part.begin(), part.end());
  }
  tbs_out = der_wrap(0x30, tbs_body);
  return true;
}

inline bool assemble_x509_certificate(const std::vector<uint8_t>& tbs,
                                      const uint8_t raw_sig[64],
                                      std::vector<uint8_t>& cert_out) {
  cert_out.clear();
  if (tbs.empty() || !raw_sig) return false;
  std::vector<uint8_t> der_sig;
  if (!raw_signature_to_der(raw_sig, 64, der_sig)) return false;
  const std::vector<uint8_t> sig_alg = der_wrap(
      0x30, der_wrap(0x06, {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02}));
  std::vector<uint8_t> sig_bits = {0x00};
  sig_bits.insert(sig_bits.end(), der_sig.begin(), der_sig.end());
  const std::vector<uint8_t> sig_bitstr = der_wrap(0x03, sig_bits);
  std::vector<uint8_t> cert_body = tbs;
  cert_body.insert(cert_body.end(), sig_alg.begin(), sig_alg.end());
  cert_body.insert(cert_body.end(), sig_bitstr.begin(), sig_bitstr.end());
  cert_out = der_wrap(0x30, cert_body);
  return true;
}

inline bool extract_x509_tbs_and_raw_signature(const std::vector<uint8_t>& cert,
                                               std::vector<uint8_t>& tbs_out,
                                               uint8_t raw_sig_out[64]) {
  tbs_out.clear();
  SecureZeroMemory(raw_sig_out, 64);
  auto read_node = [](const uint8_t* buf, size_t len, size_t& pos,
                      uint8_t expected_tag, const uint8_t*& node_start,
                      size_t& node_total, const uint8_t*& body_start,
                      size_t& body_len) noexcept -> bool {
    if (pos + 2 > len || buf[pos] != expected_tag) return false;
    node_start = buf + pos;
    const uint8_t l0 = buf[pos + 1];
    size_t hdr = 2;
    body_len = 0;
    if ((l0 & 0x80u) == 0) {
      body_len = l0;
    } else if (l0 == 0x81) {
      if (pos + 3 > len || buf[pos + 2] < 128) return false;
      hdr = 3;
      body_len = buf[pos + 2];
    } else if (l0 == 0x82) {
      if (pos + 4 > len) return false;
      hdr = 4;
      body_len = (static_cast<size_t>(buf[pos + 2]) << 8) | buf[pos + 3];
      if (body_len < 256) return false;
    } else {
      return false;
    }
    if (body_len > len - pos - hdr) return false;
    body_start = buf + pos + hdr;
    node_total = hdr + body_len;
    pos += node_total;
    return true;
  };
  size_t top_pos = 0;
  const uint8_t *outer_node = nullptr, *outer_body = nullptr;
  size_t outer_total = 0, outer_len = 0;
  if (!read_node(cert.data(), cert.size(), top_pos, 0x30, outer_node,
                 outer_total, outer_body, outer_len) ||
      top_pos != cert.size()) {
    return false;
  }
  size_t inner_pos = 0;
  const uint8_t *tbs_node = nullptr, *tbs_body = nullptr;
  size_t tbs_total = 0, tbs_len = 0;
  const uint8_t *alg_node = nullptr, *alg_body = nullptr;
  size_t alg_total = 0, alg_len = 0;
  const uint8_t *sig_node = nullptr, *sig_body = nullptr;
  size_t sig_total = 0, sig_len = 0;
  if (!read_node(outer_body, outer_len, inner_pos, 0x30, tbs_node, tbs_total,
                 tbs_body, tbs_len) ||
      !read_node(outer_body, outer_len, inner_pos, 0x30, alg_node, alg_total,
                 alg_body, alg_len) ||
      !read_node(outer_body, outer_len, inner_pos, 0x03, sig_node, sig_total,
                 sig_body, sig_len) ||
      inner_pos != outer_len || sig_len < 2 || sig_body[0] != 0x00) {
    return false;
  }
  tbs_out.assign(tbs_node, tbs_node + tbs_total);
  return der_signature_to_raw(sig_body + 1, sig_len - 1, raw_sig_out);
}

// Executes the bounded L1-CRYPTO sequence over an already-resolved 7-symbol API
// and injected sampler/clock. Never loads a DLL or touches the filesystem.
inline int run_l1_crypto_sequence(const L1CryptoApi& api,
                                  L1CryptoLedger& ledger) noexcept {
  if (!ledger.observe("before_work")) return 10;
  L1CryptoBufferPool pool(api, ledger);

  if (!ledger.invoke_and_check(
          PrimitiveCategory::kAbi, "abi", SHIROHA_NATIVE_ABI_VERSION,
          [&] { return static_cast<int>(api.abi()); },
          [](int status) {
            return status == static_cast<int>(SHIROHA_NATIVE_ABI_VERSION);
          })) {
    return 10;
  }

  std::array<EphemeralKeySlot, 3> keys{};
  constexpr std::array<const char*, 3> kGenSteps = {
      "gen_issuer", "gen_server", "gen_client"};

  for (size_t i = 0; i < 3; ++i) {
    uint8_t *key_buf = nullptr, *point_buf = nullptr, *counts_buf = nullptr;
    size_t key_slot = 0, point_slot = 0, counts_slot = 0;
    if (!pool.allocate(SHIROHA_NATIVE_ECDSA_PKCS8_MAX, &key_buf, &key_slot) ||
        !pool.allocate(SHIROHA_NATIVE_ECDSA_POINT_BYTES, &point_buf,
                       &point_slot) ||
        !pool.allocate(16, &counts_buf, &counts_slot)) {
      pool.release_all_remaining();
      return 10;
    }
    auto* key_written = reinterpret_cast<uint64_t*>(counts_buf);
    auto* point_written = reinterpret_cast<uint64_t*>(counts_buf + 8);
    const bool ok = ledger.invoke_and_check(
        PrimitiveCategory::kGenerateKey, kGenSteps[i], SHIROHA_NATIVE_OK,
        [&] {
          return api.generate_key(
              SHIROHA_NATIVE_ABI_VERSION, key_buf,
              SHIROHA_NATIVE_ECDSA_PKCS8_MAX, key_written, point_buf,
              SHIROHA_NATIVE_ECDSA_POINT_BYTES, point_written);
        },
        [&](int status) {
          if (status != SHIROHA_NATIVE_OK) return false;
          if (*key_written < 1 ||
              *key_written > SHIROHA_NATIVE_ECDSA_PKCS8_MAX ||
              *point_written != SHIROHA_NATIVE_ECDSA_POINT_BYTES ||
              point_buf[0] != 0x04) {
            return false;
          }
          keys[i].pkcs8_len = static_cast<size_t>(*key_written);
          std::memcpy(keys[i].pkcs8.data(), key_buf, keys[i].pkcs8_len);
          std::memcpy(keys[i].point.data(), point_buf,
                      SHIROHA_NATIVE_ECDSA_POINT_BYTES);
          return true;
        });
    const bool r3 = pool.release(counts_slot);
    const bool r2 = pool.release(point_slot);
    const bool r1 = pool.release(key_slot);
    if (!ok || !r1 || !r2 || !r3) {
      pool.release_all_remaining();
      return 10;
    }
  }

  // Server and client private keys are never needed for certificate signing;
  // wipe them immediately after key generation.
  keys[1].wipe_private();
  keys[2].wipe_private();

  constexpr std::array<CertificateRole, 3> kRoles = {
      CertificateRole::kIssuer, CertificateRole::kServer,
      CertificateRole::kClient};
  constexpr std::array<const char*, 3> kSignSteps = {
      "sign_issuer_cert", "sign_server_cert", "sign_client_cert"};
  std::array<std::vector<uint8_t>, 3> certs{};

  for (size_t i = 0; i < 3; ++i) {
    uint8_t serial16[16]{};
    for (size_t b = 0; b < 16; ++b) {
      serial16[b] = static_cast<uint8_t>((i + 1) * 17 + b);
    }
    std::vector<uint8_t> tbs;
    if (!build_x509_tbs(kRoles[i], serial16, keys[i].point.data(), tbs)) {
      ledger.stop(kSignSteps[i], -1, "ADMISSION_BLOCKED");
      pool.release_all_remaining();
      return 10;
    }
    uint8_t digest[32]{};
    sha256_digest(tbs.data(), tbs.size(), digest);

    uint8_t *key_buf = nullptr, *point_buf = nullptr, *digest_buf = nullptr,
            *sig_buf = nullptr, *count_buf = nullptr;
    size_t key_slot = 0, point_slot = 0, digest_slot = 0, sig_slot = 0,
           count_slot = 0;
    if (!pool.allocate(keys[0].pkcs8_len, &key_buf, &key_slot) ||
        !pool.allocate(SHIROHA_NATIVE_ECDSA_POINT_BYTES, &point_buf,
                       &point_slot) ||
        !pool.allocate(SHIROHA_NATIVE_ECDSA_DIGEST_BYTES, &digest_buf,
                       &digest_slot) ||
        !pool.allocate(SHIROHA_NATIVE_ECDSA_RAW_BYTES, &sig_buf, &sig_slot) ||
        !pool.allocate(8, &count_buf, &count_slot)) {
      pool.release_all_remaining();
      return 10;
    }
    std::memcpy(key_buf, keys[0].pkcs8.data(), keys[0].pkcs8_len);
    std::memcpy(point_buf, keys[0].point.data(),
                SHIROHA_NATIVE_ECDSA_POINT_BYTES);
    std::memcpy(digest_buf, digest, SHIROHA_NATIVE_ECDSA_DIGEST_BYTES);
    auto* sig_written = reinterpret_cast<uint64_t*>(count_buf);

    const bool ok = ledger.invoke_and_check(
        PrimitiveCategory::kCertificateEncodeSign, kSignSteps[i],
        SHIROHA_NATIVE_OK,
        [&] {
          return api.sign_digest(
              SHIROHA_NATIVE_ABI_VERSION, key_buf, keys[0].pkcs8_len, point_buf,
              SHIROHA_NATIVE_ECDSA_POINT_BYTES, digest_buf,
              SHIROHA_NATIVE_ECDSA_DIGEST_BYTES, sig_buf,
              SHIROHA_NATIVE_ECDSA_RAW_BYTES, sig_written);
        },
        [&](int status) {
          if (status != SHIROHA_NATIVE_OK ||
              *sig_written != SHIROHA_NATIVE_ECDSA_RAW_BYTES) {
            return false;
          }
          return assemble_x509_certificate(tbs, sig_buf, certs[i]);
        });
    const bool r5 = pool.release(count_slot);
    const bool r4 = pool.release(sig_slot);
    const bool r3 = pool.release(digest_slot);
    const bool r2 = pool.release(point_slot);
    const bool r1 = pool.release(key_slot);
    if (!ok || !r1 || !r2 || !r3 || !r4 || !r5) {
      keys[0].wipe_private();
      pool.release_all_remaining();
      return 10;
    }
  }
  // Issuer private key is wiped immediately after issuing the 3 test certs.
  keys[0].wipe_private();

  constexpr std::array<const char*, 3> kVerifyValidSteps = {
      "verify_issuer_valid", "verify_server_valid", "verify_client_valid"};
  constexpr std::array<const char*, 3> kVerifyTamperedSteps = {
      "verify_issuer_tampered", "verify_server_tampered",
      "verify_client_tampered"};

  for (int pass = 0; pass < 2; ++pass) {
    const bool tampered = (pass == 1);
    for (size_t i = 0; i < 3; ++i) {
      const char* step =
          tampered ? kVerifyTamperedSteps[i] : kVerifyValidSteps[i];
      std::vector<uint8_t> extracted_tbs;
      uint8_t raw_sig[64]{};
      if (!extract_x509_tbs_and_raw_signature(certs[i], extracted_tbs,
                                              raw_sig)) {
        ledger.stop(step, -1, "ADMISSION_BLOCKED");
        pool.release_all_remaining();
        return 10;
      }
      uint8_t digest[32]{};
      sha256_digest(extracted_tbs.data(), extracted_tbs.size(), digest);
      if (tampered) {
        raw_sig[0] ^= 0x01u;
      }

      uint8_t *point_buf = nullptr, *digest_buf = nullptr, *sig_buf = nullptr;
      size_t point_slot = 0, digest_slot = 0, sig_slot = 0;
      if (!pool.allocate(SHIROHA_NATIVE_ECDSA_POINT_BYTES, &point_buf,
                         &point_slot) ||
          !pool.allocate(SHIROHA_NATIVE_ECDSA_DIGEST_BYTES, &digest_buf,
                         &digest_slot) ||
          !pool.allocate(SHIROHA_NATIVE_ECDSA_RAW_BYTES, &sig_buf, &sig_slot)) {
        pool.release_all_remaining();
        return 10;
      }
      std::memcpy(point_buf, keys[0].point.data(),
                  SHIROHA_NATIVE_ECDSA_POINT_BYTES);
      std::memcpy(digest_buf, digest, SHIROHA_NATIVE_ECDSA_DIGEST_BYTES);
      std::memcpy(sig_buf, raw_sig, SHIROHA_NATIVE_ECDSA_RAW_BYTES);
      SecureZeroMemory(raw_sig, sizeof(raw_sig));

      const bool ok = ledger.invoke_and_check(
          tampered ? PrimitiveCategory::kVerifyNegative
                   : PrimitiveCategory::kVerifyPositive,
          step,
          tampered ? SHIROHA_NATIVE_VERIFICATION_REJECTED : SHIROHA_NATIVE_OK,
          [&] {
            return api.verify_digest(
                SHIROHA_NATIVE_ABI_VERSION, point_buf,
                SHIROHA_NATIVE_ECDSA_POINT_BYTES, digest_buf,
                SHIROHA_NATIVE_ECDSA_DIGEST_BYTES, sig_buf,
                SHIROHA_NATIVE_ECDSA_RAW_BYTES);
          },
          [](int) { return true; });
      const bool r3 = pool.release(sig_slot);
      const bool r2 = pool.release(digest_slot);
      const bool r1 = pool.release(point_slot);
      if (!ok || !r1 || !r2 || !r3) {
        pool.release_all_remaining();
        return 10;
      }
    }
  }

  struct PolicyCase {
    const char* step;
    size_t cert_index;
    uint32_t role;
    PrimitiveCategory category;
    int expected_status;
  };
  const std::array<PolicyCase, 3> policy_cases = {{
      {"policy_server_valid", 1, 1u, PrimitiveCategory::kPeerPolicyPositive,
       SHIROHA_NATIVE_OK},
      {"policy_client_valid", 2, 2u, PrimitiveCategory::kPeerPolicyPositive,
       SHIROHA_NATIVE_OK},
      {"policy_role_mismatch", 1, 2u, PrimitiveCategory::kPeerPolicyNegative,
       SHIROHA_NATIVE_VERIFICATION_REJECTED},
  }};

  for (const auto& tc : policy_cases) {
    const auto& der = certs[tc.cert_index];
    uint8_t* der_buf = nullptr;
    size_t der_slot = 0;
    if (!pool.allocate(der.size(), &der_buf, &der_slot)) {
      pool.release_all_remaining();
      return 10;
    }
    std::memcpy(der_buf, der.data(), der.size());
    const bool ok = ledger.invoke_and_check(
        tc.category, tc.step, tc.expected_status,
        [&] {
          return api.peer_certificate_policy(
              SHIROHA_NATIVE_ABI_VERSION, der_buf,
              static_cast<uint64_t>(der.size()), tc.role);
        },
        [](int) { return true; });
    const bool r1 = pool.release(der_slot);
    if (!ok || !r1) {
      pool.release_all_remaining();
      return 10;
    }
  }

  pool.release_all_remaining();
  if (!ledger.observe("after_final_settlement")) return 10;
  return std::strcmp(ledger.verdict(), "PASS") == 0 ? 0 : 10;
}

// Default-deny gate shared by the compiled candidate and fake entry tests.
// No CLI flag, environment variable or build define bypasses this gate in E0.
template <typename Invoke>
int l1_crypto_candidate_entry(int argc, const wchar_t* const* argv,
                              Invoke&& invoke) noexcept {
  const auto uninvoked = &std::decay_t<Invoke>::operator();
  static_cast<void>(uninvoked);
  static_cast<void>(invoke);
  if (argc < 1 || argc > 3 || !argv) return 64;
  if (argc >= 2 && (!argv[1] || argv[1][0] == L'\0')) return 64;
  std::printf(
      "STOP stage=l1_crypto_execution_not_authorized "
      "failure_code=ADMISSION_BLOCKED attempted_native=0\n");
  return 10;
}

}  // namespace shiroha_l1_crypto

#endif  // SHIROHA_L1_CRYPTO_PROBE_H_
