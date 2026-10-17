#ifndef SHIROHA_L1_WINDOWS_OPERATIONS_H_
#define SHIROHA_L1_WINDOWS_OPERATIONS_H_
#include "diagnostics/l1_windows_admission.h"
#include "diagnostics/l1_e4_admission.h"

namespace shiroha_l1_crypto {
// Borrowed handles only, no pathname or directory discovery/creation/cleanup.
// A future trusted issuer must freeze parent-chain identity and this exact pin.
struct WindowsObjectPin {
  HANDLE handle = INVALID_HANDLE_VALUE;
  FILE_ID_INFO identity{};
  std::wstring owner_sid;
  // Artifact-only frozen Owner/DACL SDDL digest. Control records retain the
  // stricter single-owner protected ACL recipe; system DLLs are never re-ACLed.
  std::string artifact_security_sha256;
};

// SOURCE/COMPILE ONLY. No executable links this object library. This backend
// deliberately has no trusted approval or durable request-journal provider.
// It cannot turn a caller's configuration into real execution authority.
class Win32AdmissionOperations final : public WindowsOperations {
 public:
  bool trusted_approval(const WindowsBinding &) noexcept override;
  bool inspect(WindowsBinding &) noexcept override;
  bool now(uint64_t &) noexcept override;
  ConsumptionRecord consume_once(const WindowsBinding &,
                                 uint64_t) noexcept override;
  WorkerState start_worker(const WindowsBinding &) noexcept override;
  WorkerObservation observe_worker() noexcept override;
};

// Leaf candidates only; MUST NOT be invoked in L0. These do not issue grants,
// establish trust, prove a parent chain or assert power-loss durability.
bool inspect_exact_token(HANDLE process, const std::wstring &sid) noexcept;
bool inspect_pinned_object(const WindowsObjectPin &pin) noexcept;
ConsumptionRecord burn_pinned_grant(const WindowsObjectPin &pin) noexcept;
bool observe_process(HANDLE process, ResourceSample &sample, bool &exited,
                     bool &normal_exit) noexcept;

// E4 unlinked SOURCE candidates. All handles/paths are caller-owned frozen
// inputs; no discovery, default root, reissue, cleanup or runtime entry exists.
bool inspect_e4_pin(const WindowsObjectPin &,bool directory,uint64_t length) noexcept;
bool inspect_e4_parent_chain(const std::vector<WindowsObjectPin> &) noexcept;
bool create_e4_record(const WindowsObjectPin &parent, const wchar_t *fixed_name,
                      uint64_t length, HANDLE &owned) noexcept;
bool write_e4_record(const WindowsObjectPin &, const uint8_t *,
                     DWORD length) noexcept;
bool read_e4_clock(e4::ClockReading &, uint64_t controller_session) noexcept;
struct SuspendedWorkerCustody {
  PROCESS_INFORMATION process{};
  bool created = false, resume_attempted = false, resume_unknown = false;
  bool token_checked = false, image_checked = false,
       dependencies_checked = false, handles_checked = false;
  bool close_attempted = false;
  // No destructor: CloseHandle is not process termination. Explicit recovery
  // and final handle-close authority must be ruled before any real L1 launch.
};
bool create_e4_suspended(const GrantTarget &, e4::ClockReading launch_clock,
                         const WindowsObjectPin &image,
                         const std::string &image_sha256,
                         const WindowsObjectPin &directory, HANDLE *ipc_handles,
                         size_t count, SuspendedWorkerCustody &) noexcept;
bool inspect_e4_image(HANDLE process, const WindowsObjectPin &image) noexcept;
bool verify_e4_artifact(const WindowsObjectPin &,
                        const std::string &expected_sha256) noexcept;
bool inspect_e4_dependencies(HANDLE process,
                             const std::vector<WindowsObjectPin> &,
                             const std::vector<std::string> &hashes) noexcept;
bool create_e4_pipe_pair(HANDLE (&ends)[4]) noexcept;
e4::Chunk read_e4_pipe_chunk(HANDLE, uint8_t *, size_t,
                             uint64_t deadline_mono) noexcept;
bool resume_e4_once(SuspendedWorkerCustody &) noexcept;
bool close_e4_observed_exit(SuspendedWorkerCustody &) noexcept;
bool show_e4_approval(const e4::ApprovalPromptModel &,
                      e4::ApprovalUiResponse &) noexcept;
class E4WindowsGrantIo final : public e4::GrantIo {
public:
  E4WindowsGrantIo(WindowsObjectPin parent, std::vector<WindowsObjectPin> chain)
      : parent_(parent), chain_(std::move(chain)) {}
  E4WindowsGrantIo(const E4WindowsGrantIo &) = delete;
  bool principal(const std::wstring &) override;
  e4::IoResult issue_new(const e4::Receipt &, BatchObjectPins &) override;
  bool inspect(const BatchObjectPins &) override;
  e4::IoResult request_new(const e4::Journal &) override;
  e4::IoResult burn_issued() override;
  e4::IoResult update_request(const e4::Journal &) override;
  // E5 explicit one-attempt owned record closure; never closes borrowed pins.
  bool close_owned_records() noexcept;
  // Deliberately no destructor/cleanup. Once invoked (separate L1 permission),
  // explicit owned close accounting is required, never a silent retry or
  // delete.
private:
  WindowsObjectPin parent_, receipt_, grant_, journal_;
  std::vector<WindowsObjectPin> chain_;
  bool issue_attempted_ = false, request_attempted_ = false;
  bool close_attempted_ = false, close_complete_ = false;
};
} // namespace shiroha_l1_crypto
#endif
