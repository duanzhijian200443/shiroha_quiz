#ifndef SHIROHA_L1_TRIAL1A_REAL_H_
#define SHIROHA_L1_TRIAL1A_REAL_H_
#include "diagnostics/l1_trial1a_pins.h"
#include <memory>

namespace shiroha_l1_crypto::trial1a {
// A typed reviewed packet, NOT a config loader or an approval boolean. Dynamic
// process identity must be absent until the launched entry observes itself.
struct Invocation {
  PinPlan plan;
  std::string case_id, permit_owner, reviewed_binding, entry_module_id;
  r2::ResourceLimit resources;
  uint32_t observations = 0;
  uint64_t duration_ms = 0;
  s1::Counts budget{};
  bool valid() const;
  std::string hash() const;
};
s1::Counts observation_cost();
s1::Counts entry_module_cost();
s1::Counts invocation_ceiling(const Invocation &);
e4::ApprovalPromptModel invocation_prompt(const Invocation &);
struct Observation {
  s1::Runtime runtime;
  e4::ClockReading clock;
  ResourceSample resources;
};
// Existing UI and R2 persistence adapters implement these finite actions. No
// issuance, 1B Grant, resume, retry, deletion or replacement operation exists.
struct InvocationPort {
  virtual ~InvocationPort() = default;
  virtual r1::Origin origin() const noexcept = 0;
  virtual bool approve(const e4::ApprovalPromptModel &,
                       e4::ApprovalUiResponse &) = 0;
  virtual Observation observe() = 0;
  virtual bool attach(const PinPlan &) = 0; // in-memory; zero I/O
  virtual bool entry_module(const std::string &id) = 0;
  virtual r1::SinkReceipt consume(const r1::Record &) = 0;
  virtual r1::SinkReceipt finish(const r1::Record &) = 0;
  virtual bool close_permit(const std::string &owner) = 0;
};
struct InvocationResult {
  bool attempted = false, approved = false, consumed = false, prepared = false,
       settled = false, unknown = false;
  uint32_t entry_starts = 0, approvals = 0, observations = 0,
           consume_attempts = 0, finish_attempts = 0, permit_closes = 0;
  uint32_t pid = 0;
  uint32_t preconsume_process_checks = 0;
  uint32_t entry_module_checks = 0;
  uint64_t creation = 0;
  uint64_t utc_ms = 0, mono_ms = 0;
  ResourceSample peak{};
  s1::Counts reserved{};
  r1::Record last;
};
// One actual state machine for Fake and Windows. The Windows origin is private
// to the concrete Windows composition; existing public entry denials remain.
class RealEntry final : private PinPort,
                        private s1::Operations,
                        private ProcessPort,
                        private r1::EvidenceSink {
public:
  RealEntry(Invocation, InvocationPort &, PinPort &, s1::Operations &,
            ProcessPort &, r1::EvidenceSink &);
  RealEntry(const RealEntry &) = delete;
  RealEntry &operator=(const RealEntry &) = delete;
  bool run_offline();
  const InvocationResult &result() const { return result_; }
  const Acquisition *acquisition() const { return acquisition_.get(); }

private:
  friend class WindowsRealEntry;
  friend class Bootstrap;
  bool run(r1::Origin);
  bool stop();
  bool reserve(const s1::Counts &);
  bool checkpoint();
  bool receipt(const r1::SinkReceipt &, const r1::Record &) const;
  r1::Record record(r1::Stage);
  r1::Origin origin() const noexcept override { return expected_; }
  AcquiredPin acquire(size_t, const PinInput &, uintptr_t) override;
  s1::Handoff bind(const PinPlan &, const std::vector<AcquiredPin> &) override;
  s1::Handoff release_borrow(const std::string &, const std::string &) override;
  bool close(size_t, const std::string &, uintptr_t) override;
  ProcessObservation measure() override;
  s1::Runtime identity() override;
  s1::Observation parent(size_t) override;
  bool artifact(size_t, r1::Pin &, uint32_t &) override;
  s1::Creation create_root() override;
  s1::Observation root() override;
  bool open_evidence() override;
  s1::Handoff handoff(const r1::Pin &, const std::string &) override;
  bool close_root() override;
  bool close_evidence() override;
  r1::SinkReceipt preserve(const r1::Record &) override;
  const Invocation request_;
  InvocationPort &control_;
  PinPort &pins_;
  s1::Operations &operations_;
  ProcessPort &process_;
  r1::EvidenceSink &sink_;
  PinPlan runtime_;
  std::unique_ptr<Acquisition> acquisition_;
  InvocationResult result_;
  s1::Counts overhead_{};
  r1::Origin expected_ = r1::Origin::kUnavailable;
  e4::ClockValidator clock_;
  uint64_t start_ = 0;
  bool stopped_ = false, initialized_ = false;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
