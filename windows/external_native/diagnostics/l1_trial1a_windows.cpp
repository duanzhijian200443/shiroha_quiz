#include "diagnostics/l1_trial1a_windows.h"
namespace shiroha_l1_crypto::trial1a {
namespace {
s1::Request bind(const Target &t) {
  auto q = t.preparation;
  q.entry_binding = t.hash();
  return q;
}
ObjectIdentityPin object(const FILE_ID_INFO &id) {
  ObjectIdentityPin p;
  p.volume_serial = id.VolumeSerialNumber;
  std::memcpy(p.file_id.data(), id.FileId.Identifier, 16);
  return p;
}
} // namespace
WindowsEntry::WindowsEntry(Target t, r2::WindowsProcessPin p,
                           std::vector<WindowsObjectPin> parents,
                           std::vector<r2::WindowsPinSpec> artifacts,
                           std::vector<WindowsObjectPin> evidence)
    : target_(std::move(t)), process_(std::move(p)),
      receiver_(target_.preparation.frozen.manifest.pin_owner,
                bind(target_).hash()),
      preparation_(bind(target_), process_.process, std::move(parents),
                   std::move(artifacts), std::move(evidence), receiver_),
      entry_(target_, preparation_, preparation_.sink_, *this) {}
ProcessObservation WindowsEntry::measure() {
  ProcessObservation m;
  // inspect_process_pin checks actual PID/time, exact token permissions, and
  // process image opened read-only against retained File ID; both temp owners
  // must close successfully. S1 later hashes the retained artifact exactly
  // once.
  if (process_.pid != GetCurrentProcessId() || process_.pid != target_.pid ||
      process_.creation != target_.creation ||
      !r2::inspect_process_pin(process_, target_.preparation.frozen.target.sid))
    return m;
  std::wstring path;
  if (!r2::measure_metadata(process_.image, false, m.security_sha256, path))
    return m;
  m.origin = r1::Origin::kWindowsApi;
  m.pid = process_.pid;
  m.creation = process_.creation;
  m.image = object(process_.image.identity);
  m.checked = true;
  return m;
}
} // namespace shiroha_l1_crypto::trial1a
