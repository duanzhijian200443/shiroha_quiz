#ifndef SHIROHA_L1_S1_WINDOWS_H_
#define SHIROHA_L1_S1_WINDOWS_H_
#include "diagnostics/l1_r2_windows.h"
#include "diagnostics/l1_s1_root.h"

namespace shiroha_l1_crypto::trial1a {
class WindowsEntry;
class WindowsPinAcquisition;
}

namespace shiroha_l1_crypto::s1 {
// Compile-only, no executable links these leaves. No discovery of paths/SID.
// Receiver borrows the pinned HANDLE; the Preparation's named pin Owner keeps
// sole close responsibility. Receipt is a retention ACK, never approval.
class PinReceiver final {
public:
  PinReceiver(std::string owner, std::string request)
      : owner_(std::move(owner)), request_(std::move(request)) {}
  PinReceiver(const PinReceiver &) = delete;
  PinReceiver &operator=(const PinReceiver &) = delete;
  Handoff retain(const r2::WindowsPinSpec &, const std::string &);
  const r2::WindowsPinSpec &borrowed() const { return borrowed_; }

private:
  const std::string owner_, request_;
  r2::WindowsPinSpec borrowed_;
  bool attempted_ = false;
};
class WindowsPreparation final : private Operations,
                                 private r2::PersistencePort {
public:
  WindowsPreparation(Request, HANDLE approved_process,
                     std::vector<WindowsObjectPin> parents,
                     std::vector<r2::WindowsPinSpec> artifacts,
                     std::vector<WindowsObjectPin> evidence_parents,
                     PinReceiver &);
  WindowsPreparation(const WindowsPreparation &) = delete;
  WindowsPreparation &operator=(const WindowsPreparation &) = delete;
  bool run(); // always rejects before ANY OS operation
  bool close_root_once(const std::string &owner) {
    return preparation_.close_root_once(owner);
  }
  bool close_evidence_once(const std::string &owner) {
    return preparation_.close_evidence_once(owner);
  }
  const Result &result() const { return preparation_.result(); }
  // No destructor CloseHandle, cleanup, delete, reopen or retry.
private:
  friend class trial1a::WindowsEntry;
  friend class trial1a::WindowsPinAcquisition;
  r1::Origin origin() const noexcept override {
    return r1::Origin::kWindowsApi;
  }
  Runtime identity() override;
  Observation parent(size_t) override;
  bool artifact(size_t, r1::Pin &, uint32_t &) override;
  Creation create_root() override;
  Observation root() override;
  bool open_evidence() override;
  Handoff handoff(const r1::Pin &, const std::string &) override;
  bool close_root() override;
  bool close_evidence() override;
  bool inspect_destination() override;
  r2::WriteStatus write(const uint8_t *, size_t, size_t &) override;
  r2::WriteStatus flush() override;
  bool evidence_chain();
  const Request request_;
  HANDLE process_; // borrowed, never closed here
  std::vector<WindowsObjectPin> parents_, evidence_parents_;
  std::vector<r2::WindowsPinSpec> artifacts_;
  PinReceiver &receiver_;
  WindowsObjectPin root_; // owned only after NtCreateFile, actual ID read later
  r2::WindowsPersistence disk_;
  r2::PersistentEvidence sink_;
  Preparation preparation_;
  bool create_attempted_ = false, root_close_attempted_ = false,
       root_created_ = false;
};
} // namespace shiroha_l1_crypto::s1
#endif
