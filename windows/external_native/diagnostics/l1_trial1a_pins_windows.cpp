// SOURCE/COMPILE ONLY: no L0 test or executable may call these leaves.
#include "diagnostics/l1_trial1a_pins_windows.h"
#include <winternl.h>
namespace shiroha_l1_crypto::trial1a {
namespace {
ObjectIdentityPin object_identity(const FILE_ID_INFO &id) {
  ObjectIdentityPin o;
  o.volume_serial = id.VolumeSerialNumber;
  std::copy_n(id.FileId.Identifier, 16, o.file_id.begin());
  return o;
}
std::wstring wide(const std::string &s) { return {s.begin(), s.end()}; }
} // namespace
WindowsPinAcquisition::WindowsPinAcquisition(PinPlan p)
    : plan_(std::move(p)), acquisition_(plan_, *this, *this, *this, *this) {}
AcquiredPin WindowsPinAcquisition::acquire(size_t i, const PinInput &input,
                                           uintptr_t parent) {
  AcquiredPin result;
  // No failed open can be repeated, even if a HANDLE/status was ambiguous.
  if (!plan_.valid() || i != owned_.size() || i >= plan_.objects.size() ||
      s1::pin_hash(input.expected) != s1::pin_hash(plan_.objects[i].expected) ||
      input.path != plan_.objects[i].path ||
      (i &&
       (input.parent >= owned_.size() ||
        parent != reinterpret_cast<uintptr_t>(owned_[input.parent].handle))))
    return result;
  owned_.push_back({});
  close_attempted_.push_back(false);
  auto &pin = owned_.back();
  pin.owner_sid = input.owner_sid;
  pin.artifact_security_sha256 = input.expected.security_sha256;
  bool opened = false;
  if (!i) {
    pin.handle = CreateFileW(
        L"\\\\?\\C:\\",
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
        FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    opened = pin.handle && pin.handle != INVALID_HANDLE_VALUE;
  } else {
    auto module = GetModuleHandleW(L"ntdll.dll");
    auto raw = module ? GetProcAddress(module, "NtCreateFile") : nullptr;
    decltype(&NtCreateFile) open = nullptr;
    static_assert(sizeof(raw) == sizeof(open));
    std::memcpy(&open, &raw, sizeof(raw));
    if (open) {
      auto leaf = wide(input.path.substr(input.path.find_last_of('\\') + 1));
      UNICODE_STRING name{};
      name.Buffer = leaf.data();
      name.Length = USHORT(leaf.size() * sizeof(wchar_t));
      name.MaximumLength = name.Length;
      OBJECT_ATTRIBUTES a{};
      a.Length = sizeof(a);
      a.RootDirectory = reinterpret_cast<HANDLE>(parent);
      a.ObjectName = &name;
      a.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
      IO_STATUS_BLOCK io{};
      const auto status = open(
          &pin.handle,
          (input.directory ? FILE_LIST_DIRECTORY : FILE_READ_DATA) |
              FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
          &a, &io, nullptr, 0, FILE_SHARE_READ, FILE_OPEN,
          (input.directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE) |
              FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
          nullptr, 0);
      opened = status == 0 && io.Status == 0 && io.Information == FILE_OPENED &&
               pin.handle && pin.handle != INVALID_HANDLE_VALUE;
    }
  }
  // Preserve any returned HANDLE before measurement; no close on ambiguous I/O.
  result.handle = reinterpret_cast<uintptr_t>(pin.handle);
  if (!opened ||
      !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &pin.identity,
                                    sizeof(pin.identity)))
    return result;
  std::wstring path;
  std::string security;
  if (!r2::measure_metadata(pin, input.directory, security, path))
    return result;
  result.measured.id = input.expected.id;
  result.measured.owner = input.expected.owner;
  result.measured.object =
      object_identity(pin.identity); // ACTUAL, never frozen ID copy
  result.measured.parent = i ? object_identity(owned_[input.parent].identity)
                             : result.measured.object;
  result.measured.security_sha256 = security;
  if (input.directory)
    result.measured.bytes_sha256 = s1::metadata_digest(result.measured.object);
  result.directory = input.directory;
  result.c_ntfs = result.owner_checked = true;
  result.reparse = result.delete_pending = false;
  result.exact_path = path == L"\\\\?\\" + wide(input.path);
  return result;
}
s1::Handoff WindowsPinAcquisition::bind(const PinPlan &p,
                                        const std::vector<AcquiredPin> &pins) {
  if (bind_attempted_)
    return {};
  bind_attempted_ = true;
  if (!p.valid() || p.hash() != plan_.hash() || pins.size() != owned_.size())
    return {};
  std::vector<WindowsObjectPin> parents, evidence;
  std::vector<r2::WindowsPinSpec> artifacts;
  for (auto n : p.parents)
    parents.push_back(owned_[n]);
  for (auto n : p.evidence_parents)
    evidence.push_back(owned_[n]);
  process_.process =
      GetCurrentProcess(); // borrowed pseudo-handle, never CloseHandle
  process_.pid = p.entry.pid;
  process_.creation = p.entry.creation;
  for (auto n : p.artifacts) {
    const auto &o = p.objects[n];
    r2::WindowsPinSpec spec;
    spec.id = o.expected.id;
    spec.owner = o.expected.owner;
    spec.object = owned_[n];
    spec.parent = owned_[o.parent];
    spec.artifact = true;
    for (size_t at = o.parent;; at = p.objects[at].parent) {
      spec.chain.push_back(owned_[at]);
      if (!at)
        break;
    }
    std::reverse(spec.chain.begin(), spec.chain.end());
    artifacts.push_back(std::move(spec));
    if (o.expected.id == p.entry.image_id)
      process_.image = owned_[n];
  }
  auto target = p.entry;
  target.acquisition_binding = p.hash();
  auto request = target.preparation;
  request.entry_binding = target.hash();
  receiver_ = std::make_unique<s1::PinReceiver>(
      request.frozen.manifest.pin_owner, request.hash());
  preparation_ = std::make_unique<s1::WindowsPreparation>(
      request, process_.process, std::move(parents), std::move(artifacts),
      std::move(evidence), *receiver_);
  borrow_ = borrow_hash(p, pins);
  return {r1::IoStatus::kOk, p.entry.preparation.frozen.manifest.pin_owner,
          p.hash(), borrow_};
}
s1::Handoff WindowsPinAcquisition::release_borrow(const std::string &request,
                                                  const std::string &pins) {
  if (release_attempted_)
    return {};
  release_attempted_ = true;
  if (!preparation_ || request != plan_.hash() || pins != borrow_)
    return {};
  preparation_
      .reset(); // all downstream borrows end; destructors perform NO I/O
  receiver_.reset();
  process_ = {};
  released_ = true;
  return {r1::IoStatus::kOk, plan_.entry.preparation.frozen.manifest.pin_owner,
          request, pins};
}
bool WindowsPinAcquisition::close(size_t i, const std::string &owner,
                                  uintptr_t h) {
  if (!released_ || i >= owned_.size() || close_attempted_[i] ||
      owner != plan_.entry.preparation.frozen.manifest.pin_owner ||
      h != reinterpret_cast<uintptr_t>(owned_[i].handle))
    return false;
  close_attempted_[i] = true;
  return CloseHandle(owned_[i].handle) != FALSE;
}
ProcessObservation WindowsPinAcquisition::measure() {
  return measure_entry_process(plan_.entry, process_);
}
} // namespace shiroha_l1_crypto::trial1a
