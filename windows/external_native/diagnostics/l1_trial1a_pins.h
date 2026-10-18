#ifndef SHIROHA_L1_TRIAL1A_PINS_H_
#define SHIROHA_L1_TRIAL1A_PINS_H_
#include "diagnostics/l1_trial1a_entry.h"

namespace shiroha_l1_crypto::trial1a {
// One topologically ordered, deduplicated retained inventory. Index zero is
// C:\ (self-parent); every other object opens relative to an earlier directory.
// owner_sid is private frozen input; expected.owner names the sole HANDLE
// owner.
struct PinInput {
  r1::Pin expected;
  std::string path;
  std::wstring owner_sid;
  size_t parent = 0;
  bool directory = false;
};
struct PinPlan {
  Target
      entry; // unchanged Entry sub-budget; acquisition_binding empty on input
  std::vector<PinInput> objects;
  std::vector<size_t> parents, artifacts, evidence_parents;
  s1::Counts budget{}; // ONE full 1A budget, including upstream final closes
  bool valid() const;
  std::string hash() const;
};
constexpr size_t kAcquisitionPins =
    2 * r2::kParents + r2::kPins * (r2::kParents + 1);
s1::Counts acquisition_cost(bool directory);
s1::Counts binding_cost();
s1::Counts acquisition_ceiling(const PinPlan &);
struct AcquiredPin {
  uintptr_t handle = 0;
  r1::Pin measured; // file byte digest empty: S1 alone performs the byte scan
  bool c_ntfs = false, directory = false, reparse = true, delete_pending = true,
       exact_path = false, owner_checked = false;
};
std::string borrow_hash(const PinPlan &, const std::vector<AcquiredPin> &);
struct PinPort {
  virtual ~PinPort() = default;
  virtual r1::Origin origin() const noexcept = 0;
  virtual AcquiredPin acquire(size_t, const PinInput &, uintptr_t parent) = 0;
  // Binds these SAME handles to the Entry Operations/ProcessPort supplied to
  // Acquisition. In-process borrow only; no duplicated or transferred HANDLE.
  virtual s1::Handoff bind(const PinPlan &,
                           const std::vector<AcquiredPin> &) = 0;
  virtual s1::Handoff release_borrow(const std::string &request,
                                     const std::string &pins) = 0;
  virtual bool close(size_t, const std::string &owner, uintptr_t) = 0;
};
class Acquisition final {
public:
  Acquisition(PinPlan, PinPort &, s1::Operations &, r1::EvidenceSink &,
              ProcessPort &);
  Acquisition(const Acquisition &) = delete;
  Acquisition &operator=(const Acquisition &) = delete;
  bool run_offline();
  bool run_windows() noexcept;
  bool settle_once(const std::string &pin_owner,
                   const std::string &evidence_owner);
  s1::State state() const { return failed_ ? state_ : entry_.state(); }
  s1::Counts reserved() const;
  const s1::Result &result() const { return entry_.result(); }
  const std::vector<AcquiredPin> &retained() const { return acquired_; }
  bool settled() const { return settled_; }
  size_t acquisition_attempts() const { return acquisition_attempts_; }

private:
  friend class RealEntry;
  bool run_controlled(r1::Origin);
  bool fail(s1::State = s1::State::unknown);
  bool reserve(const s1::Counts &);
  const PinPlan plan_;
  PinPort &port_;
  s1::Operations &operations_;
  ProcessPort &process_;
  Entry entry_;
  std::vector<AcquiredPin> acquired_;
  s1::Counts reserved_{};
  size_t acquisition_attempts_ = 0;
  std::string borrowed_;
  bool attempted_ = false, failed_ = false, settlement_attempted_ = false,
       settled_ = false;
  s1::State state_ = s1::State::rejected;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
