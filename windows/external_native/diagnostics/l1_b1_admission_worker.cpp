// COMPILE ONLY. Isolated Admission-only Worker composition for L1-ADMISSION.
// Links ZERO CNG/crypt32 or shiroha_native_ecdsa_*/peer_certificate_policy
// symbols and has no executable entry or runtime opt-in.
#include "diagnostics/l1_b1_unified.h"
#include "diagnostics/l1_e5_windows.h"
#include <psapi.h>

namespace shiroha_l1_crypto {
namespace b1 {
namespace {
bool monotonic(uint64_t &r) noexcept {
  r = GetTickCount64();
  return true;
}

class AdmissionLink final : public e4::WorkerLink {
 public:
  AdmissionLink(HANDLE read, HANDLE write)
      : read_(read), write_(write), wait_origin_(GetTickCount64()) {}
  bool send(const e4::Frame &f) override {
    DWORD written = 0;
    if (++sent_ > 44) return false;
    return WriteFile(write_, f.data(), DWORD(f.size()), &written, nullptr) &&
           written == f.size();
  }
  bool receive(e4::Frame &f) override {
    for (unsigned poll = 0; poll < 30000; ++poll) {
      if (GetTickCount64() - wait_origin_ >= 30000) return false;
      bool available = false;
      if (!poll_control(f, available)) return false;
      if (available) return true;
      Sleep(1);
    }
    return false;
  }
  bool checkpoint(L1CryptoLedger &l) override {
    PROCESS_MEMORY_COUNTERS counters{};
    counters.cb = sizeof(counters);
    DWORD handles = 0;
    return GetProcessMemoryInfo(GetCurrentProcess(), &counters,
                                sizeof(counters)) &&
           GetProcessHandleCount(GetCurrentProcess(), &handles) &&
           l.resources(counters.PeakWorkingSetSize, counters.PeakPagefileUsage,
                       handles);
  }
  bool poll_control(e4::Frame &f, bool &available) override {
    available = false;
    DWORD count = 0;
    if (!PeekNamedPipe(read_, nullptr, 0, nullptr, &count, nullptr))
      return false;
    if (!count) return true;
    auto chunk = read_e4_pipe_chunk(
        read_, partial_.data() + used_,
        (std::min)(size_t(count), partial_.size() - used_),
        (std::numeric_limits<uint64_t>::max)());
    if (!chunk.bytes || chunk.error || chunk.eof || chunk.timeout) return false;
    used_ += chunk.bytes;
    if (used_ == partial_.size()) {
      f = partial_;
      used_ = 0;
      available = true;
    }
    return true;
  }

 private:
  HANDLE read_, write_;
  uint64_t wait_origin_;
  e4::Frame partial_{};
  size_t used_ = 0;
  unsigned sent_ = 0;
};
}  // namespace

bool admission_only_worker(const e5::FixedTarget &frozen,
                           HANDLE controller_read,
                           HANDLE controller_write) noexcept {
  if (!frozen.valid() || !frozen.grant.is_admission_only() ||
      !controller_read || !controller_write ||
      controller_read == controller_write ||
      GetFileType(controller_read) != FILE_TYPE_PIPE ||
      GetFileType(controller_write) != FILE_TYPE_PIPE)
    return false;
  bool complete = false;
  try {
    AdmissionLink link(controller_read, controller_write);
    complete = admission_only_worker_candidate(
        link, frozen, GetCurrentProcessId(), monotonic);
  } catch (...) {
    complete = false;
  }
  // Each inherited IPC owner is closed exactly once even on protocol failure.
  bool read_closed = CloseHandle(controller_read) != FALSE;
  bool write_closed = CloseHandle(controller_write) != FALSE;
  return complete && read_closed && write_closed;
}
}  // namespace b1
}  // namespace shiroha_l1_crypto
