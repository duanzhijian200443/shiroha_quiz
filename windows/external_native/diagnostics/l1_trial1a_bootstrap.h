#ifndef SHIROHA_L1_TRIAL1A_BOOTSTRAP_H_
#define SHIROHA_L1_TRIAL1A_BOOTSTRAP_H_
#include "diagnostics/l1_trial1a_real.h"
#include <atomic>

namespace shiroha_l1_crypto::trial1a {
enum class EntryExit : int { settled = 0, denied = 10, unknown = 20 };
// One start per loaded process image, even after invalid input or exceptions.
// Owner is retained for process lifetime; this gate never performs OS cleanup.
class ProcessLatch final {
public:
  template <class Owner, class... Args>
  EntryExit start(const Invocation *packet, const InvocationResult **result,
                  Args &&...args) noexcept {
    if (started_.test_and_set() || !packet || !result)
      return EntryExit::denied;
    *result = nullptr;
    try {
      if (!packet->valid())
        return EntryExit::denied;
      auto *owner = new Owner(*packet, std::forward<Args>(args)...);
      custody_ = owner;
      *result = &owner->result();
      return owner->run_entry();
    } catch (...) {
      return EntryExit::unknown;
    }
  }

private:
  std::atomic_flag started_ = ATOMIC_FLAG_INIT;
  const void *custody_ = nullptr;
};
// The process bootstrap owns the SAME invocation for its entire lifetime.
// No argv/config parser, grant issuance, retry or automatic cleanup exists.
class Bootstrap final {
public:
  Bootstrap(Invocation, InvocationPort &, PinPort &, s1::Operations &,
            ProcessPort &, r1::EvidenceSink &);
  EntryExit run_offline();
  const InvocationResult &result() const { return entry_.result(); }
  const Acquisition *acquisition() const { return entry_.acquisition(); }

private:
  friend class WindowsRealEntry;
  EntryExit run(r1::Origin);
  RealEntry entry_;
  bool started_ = false;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
