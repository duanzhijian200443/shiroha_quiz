#ifndef SHIROHA_L1_TRIAL1A_REAL_WINDOWS_H_
#define SHIROHA_L1_TRIAL1A_REAL_WINDOWS_H_
#include "diagnostics/l1_trial1a_pins_windows.h"
#include "diagnostics/l1_trial1a_real.h"

namespace shiroha_l1_crypto::trial1a {
// Actual typed Windows composition, compiled but NEVER called by L0/CTest or
// the default refusal EXE. No CLI/env/JSON/config activation. Construction is
// pure. A reviewed launcher may call run only under a separate real grant.
class WindowsRealEntry final : private InvocationPort,
                               private PinPort,
                               private s1::Operations,
                               private ProcessPort,
                               private r1::EvidenceSink {
public:
  explicit WindowsRealEntry(Invocation);
  bool run() noexcept;
  const InvocationResult &result() const { return entry_.result(); }
  const s1::Result *preparation_result() const {
    const auto *a = entry_.acquisition();
    return a ? &a->result() : nullptr; // actual root Pin and owning S1 ledger
  }

private:
  r1::Origin origin() const noexcept override {
    return r1::Origin::kWindowsApi;
  }
  bool approve(const e4::ApprovalPromptModel &,
               e4::ApprovalUiResponse &) override;
  Observation observe() override;
  bool attach(const PinPlan &) override;
  r1::SinkReceipt consume(const r1::Record &) override;
  r1::SinkReceipt finish(const r1::Record &) override;
  bool close_permit(const std::string &) override;
  AcquiredPin acquire(size_t i, const PinInput &p, uintptr_t h) override {
    return windows_->acquire(i, p, h);
  }
  s1::Handoff bind(const PinPlan &p,
                   const std::vector<AcquiredPin> &v) override {
    return windows_->bind(p, v);
  }
  s1::Handoff release_borrow(const std::string &r,
                             const std::string &h) override {
    return windows_->release_borrow(r, h);
  }
  bool close(size_t i, const std::string &o, uintptr_t h) override {
    return windows_->close(i, o, h);
  }
  ProcessObservation measure() override { return windows_->measure(); }
  s1::Runtime identity() override { return windows_->identity(); }
  s1::Observation parent(size_t i) override { return windows_->parent(i); }
  bool artifact(size_t i, r1::Pin &p, uint32_t &n) override {
    return windows_->artifact(i, p, n);
  }
  s1::Creation create_root() override { return windows_->create_root(); }
  s1::Observation root() override { return windows_->root(); }
  bool open_evidence() override { return windows_->open_evidence(); }
  s1::Handoff handoff(const r1::Pin &p, const std::string &h) override {
    return windows_->handoff(p, h);
  }
  bool close_root() override { return windows_->close_root(); }
  bool close_evidence() override { return windows_->close_evidence(); }
  r1::SinkReceipt preserve(const r1::Record &r) override {
    return windows_->preserve(r);
  }
  const Invocation request_;
  std::unique_ptr<WindowsPinAcquisition> windows_;
  std::unique_ptr<r2::WindowsPersistence> permit_file_;
  std::unique_ptr<r2::PersistentEvidence> permit_;
  RealEntry entry_;
  bool attached_ = false, consumed_ = false, finished_ = false, closed_ = false;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
