#ifndef SHIROHA_L1_TRIAL1A_ENTRY_H_
#define SHIROHA_L1_TRIAL1A_ENTRY_H_
#include "diagnostics/l1_s1_root.h"

namespace shiroha_l1_crypto::trial1a {
// Typed, caller-retained fixed inputs only. No parser, discovery or approval
// bit.
struct Target {
  s1::Request preparation; // entry_binding must be empty on input
  uint32_t pid = 0;
  uint64_t creation = 0;
  std::string process_owner, image_id;
  // Optional upstream inventory/owner/aggregate-budget binding. Not authority.
  std::string acquisition_binding;
  std::string invocation_binding; // reviewed invocation/ledger, never authority
  s1::Counts total_budget{};      // includes preflight and both retained closes
  bool valid() const;
  std::string hash() const;
};
s1::Counts process_cost();
s1::Counts ceiling(const s1::Request &);
struct ProcessObservation {
  r1::Origin origin = r1::Origin::kUnavailable;
  uint32_t pid = 0;
  uint64_t creation = 0;
  ObjectIdentityPin image;
  std::string security_sha256;
  bool checked =
      false; // exact token, process image File ID and temporary closes
};
struct ProcessPort {
  virtual ~ProcessPort() = default;
  virtual r1::Origin origin() const noexcept = 0;
  virtual ProcessObservation measure() = 0;
};
// Common injected composition. Public Windows entry denies; only the reviewed
// RealEntry -> Acquisition friend chain can reach the private Windows dispatch.
class Entry final : private s1::Operations {
public:
  Entry(Target, s1::Operations &, r1::EvidenceSink &, ProcessPort &);
  Entry(const Entry &) = delete;
  Entry &operator=(const Entry &) = delete;
  bool run_offline();
  bool run_windows() noexcept;
  bool close_root_once(const std::string &owner);
  bool close_evidence_once(const std::string &owner);
  const s1::Result &result() const { return preparation_.result(); }
  s1::State state() const { return rejected_ ? state_ : result().state; }
  s1::Failure failure() const {
    return rejected_ ? failure_ : result().failure;
  }
  s1::Counts reserved() const;
  uint32_t process_attempts() const { return process_attempts_; }

private:
  friend class Acquisition;
  bool run_controlled(r1::Origin);
  bool reject(s1::Failure, s1::State);
  bool inspect_process();
  r1::Origin origin() const noexcept override { return operations_.origin(); }
  s1::Runtime identity() override;
  s1::Observation parent(size_t i) override { return operations_.parent(i); }
  bool artifact(size_t i, r1::Pin &p, uint32_t &n) override {
    return operations_.artifact(i, p, n);
  }
  s1::Creation create_root() override {
    return inspect_process() ? operations_.create_root()
                             : s1::Creation::unknown;
  }
  s1::Observation root() override { return operations_.root(); }
  bool open_evidence() override { return operations_.open_evidence(); }
  s1::Handoff handoff(const r1::Pin &p, const std::string &h) override {
    return inspect_process() ? operations_.handoff(p, h) : s1::Handoff{};
  }
  bool close_root() override { return operations_.close_root(); }
  bool close_evidence() override { return operations_.close_evidence(); }
  const Target target_;
  s1::Operations &operations_;
  ProcessPort &process_;
  s1::Preparation preparation_;
  s1::Counts preflight_{};
  uint32_t process_attempts_ = 0;
  r1::Origin expected_origin_ = r1::Origin::kUnavailable;
  bool attempted_ = false, rejected_ = false;
  s1::State state_ = s1::State::rejected;
  s1::Failure failure_ = s1::Failure::none;
};
int process_entry(int, wchar_t **) noexcept;
} // namespace shiroha_l1_crypto::trial1a
#endif
