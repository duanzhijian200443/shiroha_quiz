#include "diagnostics/l1_trial1a_bootstrap.h"
namespace shiroha_l1_crypto::trial1a {
Bootstrap::Bootstrap(Invocation q, InvocationPort &c, PinPort &p,
                     s1::Operations &o, ProcessPort &m, r1::EvidenceSink &s)
    : entry_(std::move(q), c, p, o, m, s) {}
EntryExit Bootstrap::run_offline() { return run(r1::Origin::kFake); }
EntryExit Bootstrap::run(r1::Origin origin) {
  if (started_)
    return EntryExit::denied;
  started_ = true;
  const bool completed = entry_.run(origin);
  const auto &r = entry_.result();
  if (completed && r.settled && r.consumed && r.prepared && !r.unknown)
    return EntryExit::settled;
  return r.unknown ? EntryExit::unknown : EntryExit::denied;
}
} // namespace shiroha_l1_crypto::trial1a
