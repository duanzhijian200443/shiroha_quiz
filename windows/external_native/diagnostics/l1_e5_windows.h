#ifndef SHIROHA_L1_E5_WINDOWS_H_
#define SHIROHA_L1_E5_WINDOWS_H_
#include "diagnostics/l1_e5_controller.h"
#include "diagnostics/l1_windows_operations.h"

namespace shiroha_l1_crypto {
namespace e5 {
// Borrowed, retained pins from a FUTURE separately approved fixed composition.
// No path discovery, directory creation, ACL repair or private data access.
struct WindowsPins {
  WindowsObjectPin directory, image, controller_image;
  std::vector<WindowsObjectPin> chain, dependencies;
  std::vector<std::string> hashes;
  std::string observed_device_id, observed_os_id;
};
// Worker-side callable source only. No wmain/CLI or new executable exists.
// Future fixed image composition supplies the immutable target and the two
// inherited handles; only the controller can send target-bound ADMISSION.
bool crypto_worker(const FixedTarget &, HANDLE controller_read,
                    HANDLE controller_write) noexcept;
class WindowsPlatform final : public Platform {
public:
  WindowsPlatform(FixedTarget target, WindowsPins pins, E4WindowsGrantIo &io,
                  uint64_t session)
      : target_(std::move(target)), pins_(std::move(pins)), io_(io), session_(session) {}
  WindowsPlatform(const WindowsPlatform &) = delete;
  WindowsPlatform &operator=(const WindowsPlatform &) = delete;
  bool runtime_allowed() const noexcept override;
  bool inspect_target(const FixedTarget &) override;
  bool approve(const e4::ApprovalPromptModel &, e4::ApprovalUiResponse &) override;
  e4::ClockReading read_clock() override;
  e4::WorkerStart start_suspended(const GrantTarget &, const e4::Digest &,
                                 e4::ClockReading) override;
  Observation observe() override;
  bool next(e4::Frame &, bool &available) override;
  bool send(const e4::Frame &) override;
  bool close_observed_exit() override;
  bool close_owned_io() override;
  void handoff(const std::string &, uint32_t) noexcept override;
  const SuspendedWorkerCustody &custody() const noexcept { return custody_; }
  bool operator_handoff_required() const noexcept { return handoff_; }
private:
  bool take(e4::Frame &, bool &);
  bool close_one(HANDLE &, bool &) noexcept;
  const FixedTarget target_;
  WindowsPins pins_;
  E4WindowsGrantIo &io_;
  uint64_t session_;
  SuspendedWorkerCustody custody_{};
  HANDLE pipes_[4]{};
  bool pipe_close_attempted_[4]{};
  bool attempted_ = false, io_close_attempted_ = false, io_closed_ = false;
  bool handoff_ = false, hello_pending_ = false;
  e4::Frame partial_{}, hello_{};
  size_t used_ = 0;
};
// Sole composition owns approval/issuance/consumption/worker/supervision. This
// unlinked SOURCE candidate has NO executable entry and no runtime opt-in.
class WindowsController {
public:
  WindowsController(FixedTarget target, WindowsPins pins, uint64_t session)
      : io_(pins.directory, pins.chain), platform_(target, std::move(pins), io_, session),
        controller_(std::move(target), io_, platform_) {}
  bool begin() noexcept { return controller_.begin(); }
  bool pump() noexcept { return controller_.pump(); }
  Evidence evidence() const { return controller_.evidence(); }
  const WindowsPlatform &platform() const noexcept { return platform_; }
private:
  E4WindowsGrantIo io_;
  WindowsPlatform platform_;
  Controller controller_;
};
} // namespace e5
} // namespace shiroha_l1_crypto
#endif
