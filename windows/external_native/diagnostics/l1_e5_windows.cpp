// COMPILE ONLY, unlinked. Never invoke these Windows leaves in G0-L0.
#include "diagnostics/l1_e5_windows.h"
#include <psapi.h>

namespace shiroha_l1_crypto {
namespace e5 {
bool WindowsPlatform::runtime_allowed() const noexcept {
  return false; // Fixed runtime composition/recovery/batch authorization pending.
}
bool WindowsPlatform::inspect_target(const FixedTarget &t) {
  if (!t.valid() || t.scope.hash() != target_.scope.hash() ||
      t.grant.identity() != target_.grant.identity() || t.sid != target_.sid ||
      !session_ || pins_.observed_device_id != t.grant.device_id ||
      pins_.observed_os_id != t.grant.os_id ||
      !inspect_exact_token(GetCurrentProcess(), t.sid) ||
      !inspect_e4_parent_chain(pins_.chain) ||
      !inspect_e4_pin(pins_.directory, true, 0) ||
      pins_.chain.back().identity.VolumeSerialNumber != pins_.directory.identity.VolumeSerialNumber ||
      std::memcmp(&pins_.chain.back().identity.FileId, &pins_.directory.identity.FileId, 16) ||
      !verify_e4_artifact(pins_.image, t.grant.exe_sha256) ||
      !verify_e4_artifact(pins_.controller_image, t.scope.controller_exe_sha256) ||
      !inspect_e4_image(GetCurrentProcess(), pins_.controller_image)) return false;
  wchar_t directory[1024]{};
  DWORD n = GetFinalPathNameByHandleW(pins_.directory.handle, directory, 1024,
                                     FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  std::wstring expected = L"\\\\?\\" + std::wstring(t.scope.directory.begin(), t.scope.directory.end());
  if (!n || n >= 1024 || expected != directory || pins_.dependencies.empty() ||
      pins_.dependencies.size() > 128 ||
      pins_.dependencies.size() != pins_.hashes.size()) return false;
  CanonicalHashBuilder manifest;
  manifest.put_str("SHIROHA_L1_E5_DEPENDENCIES_V1");
  for (size_t i = 0; i < pins_.dependencies.size(); ++i) {
    const auto &pin = pins_.dependencies[i];
    if (!verify_e4_artifact(pin, pins_.hashes[i])) return false;
    for (size_t j = 0; j < i; ++j)
      if (pins_.dependencies[j].identity.VolumeSerialNumber ==
              pin.identity.VolumeSerialNumber &&
          !std::memcmp(&pins_.dependencies[j].identity.FileId,
                       &pin.identity.FileId, 16))
        return false;
    manifest.put_u64_le(pin.identity.VolumeSerialNumber);
    manifest.put_bytes(pin.identity.FileId.Identifier, 16);
    manifest.put_str(pin.artifact_security_sha256);
    manifest.put_str(pins_.hashes[i]);
  }
  return manifest.finalize_hex() == t.grant.dependency_manifest_sha256;
}
bool WindowsPlatform::approve(const e4::ApprovalPromptModel &p, e4::ApprovalUiResponse &r) {
  return show_e4_approval(p, r);
}
e4::ClockReading WindowsPlatform::read_clock() {
  e4::ClockReading r{};
  read_e4_clock(r, session_);
  return r;
}
bool WindowsPlatform::close_one(HANDLE &h, bool &attempted) noexcept {
  if (!h || h == INVALID_HANDLE_VALUE) return true;
  if (attempted) return false;
  attempted = true;
  if (!CloseHandle(h)) return false;
  h = nullptr;
  return true;
}
e4::WorkerStart WindowsPlatform::start_suspended(const GrantTarget &t,
    const e4::Digest &, e4::ClockReading launch) {
  e4::WorkerStart r{};
  if (attempted_) return r;
  attempted_ = true;
  auto expected = target_.grant;
  expected.user_approved = true;
  if (t.identity() != expected.identity() || !inspect_target(target_) ||
      !create_e4_pipe_pair(pipes_)) return r;
  HANDLE inherited[] = {pipes_[2], pipes_[1]};
  if (!create_e4_suspended(t, launch, pins_.image, t.exe_sha256, pins_.directory,
                           inherited, 2, custody_)) return r;
  r.created = true;
  r.pid = custody_.process.dwProcessId;
  // Child owns these inherited ends; parent drops each duplicate once. Failure
  // retains custody and prevents Resume rather than hiding an EOF obstruction.
  r.handles = close_one(pipes_[1], pipe_close_attempted_[1]) &&
              close_one(pipes_[2], pipe_close_attempted_[2]);
  custody_.handles_checked = r.handles;
  r.token = custody_.token_checked = inspect_exact_token(custody_.process.hProcess, target_.sid);
  r.image = custody_.image_checked = inspect_e4_image(custody_.process.hProcess, pins_.image);
  // Before loader execution, hash/pin the complete manifest; actual loaded
  // module closure is checked after HELLO, before ADMISSION. No fallback.
  r.dependencies = custody_.dependencies_checked = inspect_target(target_);
  auto fresh = read_clock();
  if (!r.handles || !r.token || !r.image || !r.dependencies ||
      !e4::window(t, fresh) || fresh.mono < launch.mono || fresh.mono - launch.mono >= 30000)
    return r;
  r.resume_attempted = true;
  r.resumed = resume_e4_once(custody_);
  r.resume_known = !custody_.resume_unknown;
  if (!r.resumed || !r.resume_known) return r;
  // Bounded loader HELLO wait; no primitive work has been admitted yet.
  for (unsigned poll = 0; poll < 30000; ++poll) {
    auto now = read_clock();
    auto o = observe();
    if (!now.valid || now.mono < launch.mono || now.mono - launch.mono >= 30000 ||
        !o.healthy || o.exited ||
        o.controller.peak_working_set > target_.scope.controller_working ||
        o.controller.peak_commit > target_.scope.controller_commit ||
        o.controller.handles > target_.scope.controller_handles ||
        o.worker.peak_working_set > t.working_set_bytes ||
        o.worker.peak_commit > t.commit_bytes || o.worker.handles > t.handles) return r;
    bool available = false;
    if (!take(hello_, available)) return r;
    if (available) {
      r.dependencies = inspect_e4_dependencies(custody_.process.hProcess, pins_.dependencies, pins_.hashes);
      r.hello = r.dependencies;
      hello_pending_ = r.hello;
      return r;
    }
    Sleep(1); // no retry of any effect; cooperative scheduling only
  }
  return r;
}
Observation WindowsPlatform::observe() {
  Observation o;
  bool controller_exited = false, normal = false;
  o.healthy = observe_process(GetCurrentProcess(), o.controller, controller_exited, normal) && !controller_exited;
  if (custody_.created) {
    o.healthy = observe_process(custody_.process.hProcess, o.worker, o.exited, o.normal_exit) && o.healthy;
  }
  return o;
}
bool WindowsPlatform::take(e4::Frame &f, bool &available) {
  available = false;
  DWORD count = 0;
  if (!PeekNamedPipe(pipes_[0], nullptr, 0, nullptr, &count, nullptr)) return false;
  if (!count) return true;
  auto chunk = read_e4_pipe_chunk(pipes_[0], partial_.data() + used_,
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
bool WindowsPlatform::next(e4::Frame &f, bool &available) {
  if (hello_pending_) {
    hello_pending_ = false;
    f = hello_;
    available = true;
    return true;
  }
  return take(f, available);
}
bool WindowsPlatform::send(const e4::Frame &f) {
  DWORD written = 0;
  // Three frames/192 bytes total fit the fixed empty 4096-byte pipe even if
  // Worker stops reading. Syscalls themselves have no cancellation guarantee.
  return WriteFile(pipes_[3], f.data(), DWORD(f.size()), &written, nullptr) && written == f.size();
}
bool WindowsPlatform::close_observed_exit() { return close_e4_observed_exit(custody_); }
bool WindowsPlatform::close_owned_io() {
  if (io_close_attempted_) return io_closed_;
  io_close_attempted_ = true;
  bool ok = io_.close_owned_records();
  for (size_t i = 0; i < 4; ++i)
    ok = close_one(pipes_[i], pipe_close_attempted_[i]) && ok;
  return io_closed_ = ok;
}
void WindowsPlatform::handoff(const std::string &, uint32_t) noexcept {
  // Retain process/thread custody for the named operator. No termination,
  // second Resume, background retry, recovery or implicit destructor close.
  handoff_ = true;
}
} // namespace e5
} // namespace shiroha_l1_crypto
