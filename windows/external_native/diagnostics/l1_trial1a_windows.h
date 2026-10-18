#ifndef SHIROHA_L1_TRIAL1A_WINDOWS_H_
#define SHIROHA_L1_TRIAL1A_WINDOWS_H_
#include "diagnostics/l1_s1_windows.h"
#include "diagnostics/l1_trial1a_entry.h"
namespace shiroha_l1_crypto::trial1a {
// OBJECT only. All incoming handles already retained by named external owners.
// No acquisition/discovery, destructor close, production adapter or Worker.
class WindowsEntry final : private ProcessPort {
public:
  WindowsEntry(Target, r2::WindowsProcessPin,
               std::vector<WindowsObjectPin> parents,
               std::vector<r2::WindowsPinSpec> artifacts,
               std::vector<WindowsObjectPin> evidence_parents);
  bool run() noexcept { return entry_.run_windows(); }
  const Entry &entry() const { return entry_; }
  bool close_root_once(const std::string &owner) {
    return entry_.close_root_once(owner);
  }
  bool close_evidence_once(const std::string &owner) {
    return entry_.close_evidence_once(owner);
  }
  const r2::WindowsPinSpec *retained_root() const {
    const auto &r = entry_.result();
    return entry_.state() == s1::State::pinned && r.evidence_preserved &&
                   !r.root_close_attempted
               ? &receiver_.borrowed()
               : nullptr;
  }

private:
  r1::Origin origin() const noexcept override {
    return r1::Origin::kWindowsApi;
  }
  ProcessObservation measure() override;
  const Target target_;
  const r2::WindowsProcessPin process_;
  s1::PinReceiver receiver_;
  s1::WindowsPreparation preparation_;
  Entry entry_;
};
} // namespace shiroha_l1_crypto::trial1a
#endif
