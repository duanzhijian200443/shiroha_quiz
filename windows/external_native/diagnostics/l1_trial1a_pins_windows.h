#ifndef SHIROHA_L1_TRIAL1A_PINS_WINDOWS_H_
#define SHIROHA_L1_TRIAL1A_PINS_WINDOWS_H_
#include "diagnostics/l1_trial1a_pins.h"
#include "diagnostics/l1_trial1a_windows.h"
#include <memory>
namespace shiroha_l1_crypto::trial1a {
// Linked only by the diagnostic entry DLL, never invoked by L0/CTest. Owns each opened inventory
// HANDLE exactly once; Entry/S1 borrow it. No destructor close/delete.
// S1 borrows the current-entry process pseudo-handle, under process_owner.
// It acquires/closes no process HANDLE (no OpenProcess or duplication).
class WindowsPinAcquisition final : private PinPort,
                                    private s1::Operations,
                                    private ProcessPort,
                                    private r1::EvidenceSink {
public:
  explicit WindowsPinAcquisition(PinPlan);
  bool run() noexcept { return acquisition_.run_windows(); }
  const Acquisition &acquisition() const { return acquisition_; }
  bool settle_once(const std::string &owner, const std::string &evidence) {
    return acquisition_.settle_once(owner, evidence);
  }
  const r2::WindowsPinSpec *retained_root() const {
    const auto &r = acquisition_.result();
    return receiver_ && acquisition_.state() == s1::State::pinned &&
                   r.evidence_preserved && !r.root_close_attempted
               ? &receiver_->borrowed()
               : nullptr;
  }

private:
  friend class WindowsRealEntry;
  r1::Origin origin() const noexcept override {
    return r1::Origin::kWindowsApi;
  }
  AcquiredPin acquire(size_t, const PinInput &, uintptr_t) override;
  s1::Handoff bind(const PinPlan &, const std::vector<AcquiredPin> &) override;
  s1::Handoff release_borrow(const std::string &, const std::string &) override;
  bool close(size_t, const std::string &, uintptr_t) override;
  ProcessObservation measure() override;
  s1::Runtime identity() override { return preparation_->identity(); }
  s1::Observation parent(size_t i) override { return preparation_->parent(i); }
  bool artifact(size_t i, r1::Pin &p, uint32_t &n) override {
    return preparation_->artifact(i, p, n);
  }
  s1::Creation create_root() override { return preparation_->create_root(); }
  s1::Observation root() override { return preparation_->root(); }
  bool open_evidence() override { return preparation_->open_evidence(); }
  s1::Handoff handoff(const r1::Pin &p, const std::string &h) override {
    return preparation_->handoff(p, h);
  }
  bool close_root() override { return preparation_->close_root(); }
  bool close_evidence() override { return preparation_->close_evidence(); }
  r1::SinkReceipt preserve(const r1::Record &r) override {
    return preparation_->sink_.preserve(r);
  }
  const PinPlan plan_;
  std::vector<WindowsObjectPin> owned_;
  std::vector<bool> close_attempted_;
  r2::WindowsProcessPin process_;
  std::unique_ptr<s1::PinReceiver> receiver_;
  std::unique_ptr<s1::WindowsPreparation> preparation_;
  Acquisition acquisition_;
  std::string borrow_;
  bool bind_attempted_ = false, release_attempted_ = false, released_ = false;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
