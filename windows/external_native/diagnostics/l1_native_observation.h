#ifndef SHIROHA_L1_NATIVE_OBSERVATION_H_
#define SHIROHA_L1_NATIVE_OBSERVATION_H_

#include <array>
#include <cstddef>
#include <cstdint>

// Non-owning, diagnostic-only observation. No OS access, allocation, logging or
// exported ABI. Production builds erase the macros below to the original call.
namespace shiroha_l1_crypto {
enum class NativeOp : size_t {
  kOpen,
  kGenerate,
  kFinalize,
  kExport,
  kImport,
  kSign,
  kVerify,
  kClose,
  kDestroy,
  kCertCreate,
  kCertFree,
  kDecode,
  kLocalFree,
  kTime,
  kCount
};
inline constexpr size_t kNativeOpCount = static_cast<size_t>(NativeOp::kCount);
inline constexpr std::array<unsigned, kNativeOpCount> kNativeLimits = {
    12, 3, 3, 3, 9, 3, 6, 12, 12, 3, 3, 20, 20, 3};
inline constexpr std::array<const char *, kNativeOpCount> kNativeNames = {
    "provider_open",    "key_generate",
    "key_finalize",     "key_export",
    "key_import",       "sign",
    "verify",           "provider_close",
    "key_destroy",      "certificate_create",
    "certificate_free", "decode",
    "local_free",       "time"};

struct CallCounts {
  unsigned attempted = 0, returned = 0, accepted = 0, settled = 0, unknown = 0;
  unsigned returned_failure = 0;
};

struct NativeObservation {
  // Diagnostic Worker session may close admission between direct native calls.
  // Release owners never consult this callback. Production macros remain erased.
  bool (*check_admission)() noexcept = nullptr;
  std::array<CallCounts, kNativeOpCount> calls{};
  unsigned acquired = 0, released = 0, still_owned = 0, quarantined = 0;
  bool stopped = false, unknown = false, first_failure_unknown = false;
  const char *first_failure = "none";

  void fail(const char *stage, bool uncertain = false) noexcept {
    if (!stopped) {
      first_failure = stage;
      first_failure_unknown = uncertain;
    }
    stopped = true;
    unknown = unknown || uncertain;
  }
  bool complete() const noexcept {
    if (stopped || unknown || still_owned || quarantined || acquired != 47 ||
        acquired != released)
      return false;
    for (size_t i = 0; i < calls.size(); ++i) {
      const auto &c = calls[i];
      if (c.attempted != kNativeLimits[i] || c.returned != c.attempted ||
          c.accepted != c.attempted || c.settled != c.attempted || c.unknown)
        return false;
    }
    return true;
  }
};

inline thread_local NativeObservation *active_native_observation = nullptr;
class NativeObservationScope {
 public:
  explicit NativeObservationScope(NativeObservation &target) noexcept
      : previous_(active_native_observation) {
    active_native_observation = &target;
  }
  ~NativeObservationScope() { active_native_observation = previous_; }
  NativeObservationScope(const NativeObservationScope &) = delete;
  NativeObservationScope &operator=(const NativeObservationScope &) = delete;

 private:
  NativeObservation *previous_;
};

template <typename Call, typename Accept, typename Result>
Result observe_native(NativeOp op, bool release, NativeObservation *observer,
                      Call &&call, Accept &&accept, Result failure) noexcept {
  if (!observer) return call();
  const auto index = static_cast<size_t>(op);
  auto &counts = observer->calls[index];
  if (!release && observer->check_admission && !observer->check_admission()) {
    observer->fail("supervisor_stop");
    return failure;
  }
  // Cleanup remains legal after STOP; a recording failure never skips another
  // owner's one release. Business operations cannot continue after first error.
  if ((!release && observer->stopped) ||
      counts.attempted >= kNativeLimits[index]) {
    observer->fail("native_budget", release);
    if (!release) return failure;
  }
  ++counts.attempted;
  try {
    const Result result = call();
    ++counts.returned;
    if (accept(result)) {
      ++counts.accepted;
      ++counts.settled;
    } else {
      ++counts.returned_failure;
      // A returned non-release failure has a known result, not a success.
      if (!release) ++counts.settled;
      observer->fail(kNativeNames[index], release);
    }
    return result;
  } catch (...) {
    ++counts.unknown;
    observer->fail(kNativeNames[index], true);
    return failure;
  }
}

template <typename Call, typename Accept, typename Result>
Result observe_native(NativeOp op, Call &&call, Accept &&accept,
                      Result failure) noexcept {
  return observe_native(op, false, active_native_observation, call, accept,
                        failure);
}

// This ticket records custody only; it never frees anything in its destructor.
// The existing RAII object remains the sole owner and sole release caller.
class NativeOwnerObservation {
 public:
  void acquire(bool present) noexcept {
    if (!present) return;
    observer_ = active_native_observation;
    if (observer_) {
      ++observer_->acquired;
      ++observer_->still_owned;
    }
    acquired_ = true;
  }
  template <typename Call, typename Accept, typename Result>
  Result release(NativeOp op, Call &&call, Accept &&accept,
                 Result failure) noexcept {
    if (!acquired_ || attempted_) {
      if (observer_) observer_->fail("duplicate_or_unowned_release", true);
      return failure;
    }
    attempted_ = true;
    const auto result =
        observe_native(op, true, observer_, call, accept, failure);
    if (observer_) {
      if (accept(result)) {
        ++observer_->released;
        --observer_->still_owned;
      } else {
        ++observer_->quarantined;
      }
    }
    return result;
  }
  NativeOwnerObservation() = default;
  NativeOwnerObservation(const NativeOwnerObservation &) = delete;
  NativeOwnerObservation &operator=(const NativeOwnerObservation &) = delete;

 private:
  NativeObservation *observer_ = nullptr;
  bool acquired_ = false, attempted_ = false;
};
}  // namespace shiroha_l1_crypto

#ifdef SHIROHA_L1_CRYPTO_OBSERVATION
#define L1_NATIVE_OWNER shiroha_l1_crypto::NativeOwnerObservation observation;
#define L1_NATIVE_ACQUIRED(present) observation.acquire(present)
#define L1_NATIVE_CALL(op, expression, accept, failure)                      \
  shiroha_l1_crypto::observe_native(                                         \
      shiroha_l1_crypto::NativeOp::op, [&] { return (expression); }, accept, \
      failure)
#define L1_NATIVE_RELEASE(op, expression, accept, failure)                   \
  observation.release(                                                       \
      shiroha_l1_crypto::NativeOp::op, [&] { return (expression); }, accept, \
      failure)
#else
#define L1_NATIVE_OWNER
#define L1_NATIVE_ACQUIRED(present) static_cast<void>(0)
#define L1_NATIVE_CALL(op, expression, accept, failure) (expression)
#define L1_NATIVE_RELEASE(op, expression, accept, failure) (expression)
#endif
#endif
