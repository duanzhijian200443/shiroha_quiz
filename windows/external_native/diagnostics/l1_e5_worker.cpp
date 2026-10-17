// COMPILE ONLY. Isolated Worker composition; no App/Bridge/Store/loader path.
#include "diagnostics/l1_e5_windows.h"
#include <psapi.h>

namespace shiroha_l1_crypto {
namespace e5 {
namespace {
bool monotonic(uint64_t &r) noexcept { r = GetTickCount64(); return true; }
void *resolve(const char *name) noexcept {
  if (!is_allowed_l1_crypto_symbol(name)) return nullptr;
  if (!std::strcmp(name, "shiroha_native_abi_version")) return reinterpret_cast<void *>(&shiroha_native_abi_version);
  if (!std::strcmp(name, "shiroha_native_buffer_alloc")) return reinterpret_cast<void *>(&shiroha_native_buffer_alloc);
  if (!std::strcmp(name, "shiroha_native_buffer_free")) return reinterpret_cast<void *>(&shiroha_native_buffer_free);
  if (!std::strcmp(name, "shiroha_native_ecdsa_generate_key")) return reinterpret_cast<void *>(&shiroha_native_ecdsa_generate_key);
  if (!std::strcmp(name, "shiroha_native_ecdsa_sign_digest")) return reinterpret_cast<void *>(&shiroha_native_ecdsa_sign_digest);
  if (!std::strcmp(name, "shiroha_native_ecdsa_verify_digest")) return reinterpret_cast<void *>(&shiroha_native_ecdsa_verify_digest);
  if (!std::strcmp(name, "shiroha_native_peer_certificate_policy")) return reinterpret_cast<void *>(&shiroha_native_peer_certificate_policy);
  return nullptr;
}
class Link final : public e4::WorkerLink {
public:
  Link(HANDLE read, HANDLE write) : read_(read), write_(write), wait_origin_(GetTickCount64()) {}
  bool send(const e4::Frame &f) override {
    DWORD written = 0;
    if (++sent_ > 44) return false;
    // 2816 bytes maximum fits the 4096-byte pipe without depending on a peer
    // draining it. A pathological kernel call is not claimed cancellable.
    return WriteFile(write_, f.data(), DWORD(f.size()), &written, nullptr) && written == f.size();
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
    return GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters)) &&
        GetProcessHandleCount(GetCurrentProcess(), &handles) &&
        l.resources(counters.PeakWorkingSetSize, counters.PeakPagefileUsage, handles);
  }
  bool poll_control(e4::Frame &f, bool &available) override {
    available = false;
    DWORD count = 0;
    if (!PeekNamedPipe(read_, nullptr, 0, nullptr, &count, nullptr)) return false;
    if (!count) return true;
    auto chunk = read_e4_pipe_chunk(read_, partial_.data() + used_,
        (std::min)(size_t(count), partial_.size() - used_),
        (std::numeric_limits<uint64_t>::max)());
    if (!chunk.bytes || chunk.error || chunk.eof || chunk.timeout) return false;
    used_ += chunk.bytes;
    if (used_ == partial_.size()) {
      f = partial_; used_ = 0; available = true;
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
} // namespace
bool crypto_worker(const FixedTarget &frozen, HANDLE read, HANDLE write) noexcept {
  if (!frozen.valid() || !read || !write || read == write ||
      GetFileType(read) != FILE_TYPE_PIPE || GetFileType(write) != FILE_TYPE_PIPE) return false;
  bool complete = false;
  try {
    Link link(read, write);
    complete = worker_candidate(link, frozen, GetCurrentProcessId(), monotonic, resolve);
  } catch (...) { complete = false; }
  // Each inherited IPC owner is closed exactly once even on protocol failure.
  // False never authorizes caller retry. Native owners remain the original RAII.
  bool read_closed = CloseHandle(read) != FALSE;
  bool write_closed = CloseHandle(write) != FALSE;
  return complete && read_closed && write_closed;
}
} // namespace e5
} // namespace shiroha_l1_crypto
