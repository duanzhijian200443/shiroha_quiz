#ifndef SHIROHA_L1_WINDOWS_OPERATIONS_H_
#define SHIROHA_L1_WINDOWS_OPERATIONS_H_
#include "diagnostics/l1_windows_admission.h"

namespace shiroha_l1_crypto {
// Borrowed handles only, no pathname or directory discovery/creation/cleanup.
// A future trusted issuer must freeze parent-chain identity and this exact pin.
struct WindowsObjectPin {
  HANDLE handle = INVALID_HANDLE_VALUE;
  FILE_ID_INFO identity{};
  std::wstring owner_sid;
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
}  // namespace shiroha_l1_crypto
#endif
