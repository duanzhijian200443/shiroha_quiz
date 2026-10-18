#include "diagnostics/l1_trial1a_real_windows.h"
namespace shiroha_l1_crypto::trial1a {
WindowsRealEntry::WindowsRealEntry(Invocation q)
    : request_(std::move(q)),
      entry_(request_, *this, *this, *this, *this, *this) {}
bool WindowsRealEntry::run() noexcept {
  return entry_.run(r1::Origin::kWindowsApi);
}
bool WindowsRealEntry::approve(const e4::ApprovalPromptModel &p,
                               e4::ApprovalUiResponse &r) {
  return p.target_hash == request_.reviewed_binding &&
         p.summary == invocation_prompt(request_).summary &&
         r2::bounded_approval(p, r, request_.plan.entry.preparation.limits);
}
Observation WindowsRealEntry::observe() {
  Observation o;
  const auto process = GetCurrentProcess(); // borrowed pseudo-HANDLE
  if (!r2::measure_runtime(process, o.runtime.facts))
    return {};
  wchar_t name[256]{};
  DWORD n = 256;
  if (!GetComputerNameExW(ComputerNamePhysicalDnsFullyQualified, name, &n) ||
      !n || n >= 256)
    return {};
  CanonicalHashBuilder device;
  device.put_str("SHIROHA_L1_R2_DEVICE_V1");
  for (DWORD i = 0; i < n; ++i)
    device.put_u16_le(uint16_t(name[i]));
  o.runtime.device_sha256 = device.finalize_hex();
  bool exited = false, normal = false;
  if (!read_e4_clock(o.clock, o.runtime.facts.creation_time) ||
      !observe_process(process, o.resources, exited, normal) || exited)
    return {};
  // observe_process's stamp may be later; one clock reading completes this
  // observation envelope and is the authoritative sample timestamp.
  if (!read_e4_clock(o.clock, o.runtime.facts.creation_time))
    return {};
  o.resources.observed_at_ms = o.clock.mono;
  return o;
}
bool WindowsRealEntry::attach(const PinPlan &p) {
  if (attached_ || !p.valid() || p.entry.invocation_binding != request_.hash())
    return false;
  attached_ = true;
  windows_ = std::make_unique<WindowsPinAcquisition>(p);
  return true;
}
r1::SinkReceipt WindowsRealEntry::consume(const r1::Record &r) {
  if (consumed_ || !windows_ || !windows_->preparation_ ||
      r.stage != r1::Stage::kConsumed)
    return {};
  consumed_ = true; // failures/partial creates never retry or reopen
  std::vector<WindowsObjectPin> chain;
  for (auto n : request_.plan.evidence_parents)
    chain.push_back(windows_->owned_[n]);
  if (chain.empty())
    return {};
  permit_file_ = std::make_unique<r2::WindowsPersistence>(
      chain.back(), chain, r2::Output::trial1a_consumption);
  // FILE_CREATE at a fixed leaf. Existing, empty, partial or corrupt tombstones
  // all reject; no read/recovery path can reissue this directory's permit.
  if (!permit_file_->open_new())
    return {};
  const auto &f = request_.plan.entry.preparation.frozen;
  permit_ = std::make_unique<r2::PersistentEvidence>(
      *permit_file_, f.target.grant.batch_id, f.hash(), request_.permit_owner,
      2);
  return permit_->preserve(r); // exact existing 8192B encoding + Write + Flush
}
r1::SinkReceipt WindowsRealEntry::finish(const r1::Record &r) {
  if (!consumed_ || finished_ || !permit_ || r.stage != r1::Stage::kFinal)
    return {};
  finished_ = true;
  return permit_->preserve(r);
}
bool WindowsRealEntry::close_permit(const std::string &owner) {
  if (closed_ || !finished_ || !permit_ || permit_->failed() ||
      owner != request_.permit_owner)
    return false;
  closed_ = true;
  return permit_file_->close_once();
}
} // namespace shiroha_l1_crypto::trial1a
