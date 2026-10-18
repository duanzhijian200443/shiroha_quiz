// COMPILE ONLY. No real entry, Fake test or production target links this file.
#include "diagnostics/l1_s1_windows.h"
#include <sddl.h>
#include <winternl.h>

namespace shiroha_l1_crypto::s1 {
namespace {
ObjectIdentityPin id(const FILE_ID_INFO &p) {
  ObjectIdentityPin out;
  out.volume_serial = p.VolumeSerialNumber;
  std::copy_n(p.FileId.Identifier, 16, out.file_id.begin());
  return out;
}
std::string metadata_hash(const ObjectIdentityPin &p) {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_R2_METADATA_ONLY_V1");
  h.put_u64_le(p.volume_serial);
  h.put_bytes(p.file_id.data(), 16);
  return h.finalize_hex();
}
std::wstring wide(const std::string &s) { return {s.begin(), s.end()}; }
bool measure(const WindowsObjectPin &p, const r1::Pin &expected,
             const std::string &path, Observation &out) {
  std::wstring actual;
  std::string sd;
  if (!r2::measure_metadata(p, true, sd, actual) ||
      actual != L"\\\\?\\" + wide(path) || id(p.identity) != expected.object ||
      sd != expected.security_sha256)
    return false;
  out.pin = expected;
  out.c_ntfs = out.directory = out.exact_path = true;
  out.reparse = out.delete_pending = false;
  return true;
}
WindowsObjectPin last(const std::vector<WindowsObjectPin> &p) {
  return p.empty() ? WindowsObjectPin{} : p.back();
}
} // namespace
Handoff PinReceiver::retain(const r2::WindowsPinSpec &spec,
                            const std::string &request) {
  if (attempted_)
    return {};
  attempted_ = true;
  if (!safe_id(owner_) || !hex_digest(request_, 64) || request != request_ ||
      !safe_id(spec.id) || spec.chain.empty() ||
      spec.chain.size() > r2::kParents || spec.owner != owner_ ||
      !spec.directory || spec.artifact || !spec.object.handle ||
      spec.object.handle == INVALID_HANDLE_VALUE ||
      !id(spec.object.identity).valid() || !id(spec.parent.identity).valid() ||
      id(spec.chain.back().identity) != id(spec.parent.identity))
    return {};
  borrowed_ =
      spec; // bounded in-memory copy; zero OS calls, never a process ACK
  r1::Pin p;
  p.id = spec.id;
  p.owner = spec.owner;
  p.object = id(spec.object.identity);
  p.parent = id(spec.parent.identity);
  p.security_sha256 = spec.object.artifact_security_sha256;
  p.bytes_sha256 = metadata_hash(p.object);
  return {r1::IoStatus::kOk, owner_, request_, pin_hash(p)};
}
WindowsPreparation::WindowsPreparation(
    Request r, HANDLE p, std::vector<WindowsObjectPin> parents,
    std::vector<r2::WindowsPinSpec> artifacts,
    std::vector<WindowsObjectPin> evidence, PinReceiver &receiver)
    : request_(std::move(r)), process_(p), parents_(std::move(parents)),
      evidence_parents_(std::move(evidence)), artifacts_(std::move(artifacts)),
      receiver_(receiver), disk_(last(evidence_parents_), evidence_parents_,
                                 r2::Output::controller_evidence),
      sink_(*this, request_.frozen.target.grant.batch_id,
            request_.frozen.hash(), request_.frozen.manifest.evidence_owner, 2),
      preparation_(request_, *this, sink_) {}
bool WindowsPreparation::run() {
  if (!windows_runtime_allowed()) {
    // run_offline rejects this WindowsApi origin without invoking a leaf.
    return preparation_.run_offline();
  }
  return preparation_.run(r1::Origin::kWindowsApi);
}
Runtime WindowsPreparation::identity() {
  Runtime out;
  if (!r2::measure_runtime(process_, out.facts))
    return {};
  wchar_t name[256]{};
  DWORD n = 256;
  if (!GetComputerNameExW(ComputerNamePhysicalDnsFullyQualified, name, &n) ||
      !n || n >= 256)
    return {};
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_R2_DEVICE_V1");
  for (DWORD i = 0; i < n; ++i)
    h.put_u16_le(uint16_t(name[i]));
  out.device_sha256 = h.finalize_hex();
  return out;
}
Observation WindowsPreparation::parent(size_t i) {
  Observation out;
  const auto paths = parent_paths(request_.frozen.target.scope.directory);
  if (parents_.size() != request_.parents.size() || i >= paths.size() ||
      i >= parents_.size())
    return out;
  measure(parents_[i], request_.parents[i], paths[i], out);
  return out;
}
bool WindowsPreparation::artifact(size_t i, r1::Pin &out, uint32_t &reads) {
  reads = 0;
  if (artifacts_.size() != request_.frozen.manifest.pins.size() ||
      i >= artifacts_.size())
    return false;
  const auto &spec = artifacts_[i];
  const auto &expected = request_.frozen.manifest.pins[i];
  if (!spec.artifact || spec.directory || spec.id != expected.id ||
      spec.owner != expected.owner ||
      id(spec.object.identity) != expected.object ||
      id(spec.parent.identity) != expected.parent || spec.chain.empty() ||
      spec.chain.size() > r2::kParents ||
      id(spec.chain.back().identity) != expected.parent)
    return false;
  std::wstring previous;
  for (const auto &p : spec.chain) {
    std::wstring path;
    std::string sd;
    if (!r2::measure_metadata(p, true, sd, path))
      return false;
    if (previous.empty()) {
      if (path != L"\\\\?\\C:\\")
        return false;
    } else {
      if (previous.back() != L'\\')
        previous += L'\\';
      if (path.compare(0, previous.size(), previous) ||
          path.size() <= previous.size() ||
          path.find(L'\\', previous.size()) != std::wstring::npos)
        return false;
    }
    previous = std::move(path);
  }
  std::wstring path;
  std::string sd, hash;
  if (!r2::measure_metadata(spec.object, false, sd, path))
    return false;
  if (previous.back() != L'\\')
    previous += L'\\';
  if (path.compare(0, previous.size(), previous) ||
      path.size() <= previous.size() ||
      path.find(L'\\', previous.size()) != std::wstring::npos ||
      !r2::measure_artifact(spec.object, hash, reads))
    return false;
  out = expected;
  out.security_sha256 = sd;
  out.bytes_sha256 = hash;
  return true;
}
Creation WindowsPreparation::create_root() {
  if (create_attempted_)
    return Creation::denied;
  create_attempted_ = true;
  if (parents_.empty() || parents_.size() != request_.parents.size())
    return Creation::denied;
  const auto &path = request_.frozen.target.scope.directory;
  auto leaf = wide(path.substr(path.find_last_of('\\') + 1));
  auto module = GetModuleHandleW(L"ntdll.dll");
  auto raw = module ? GetProcAddress(module, "NtCreateFile") : nullptr;
  decltype(&NtCreateFile) create = nullptr;
  static_assert(sizeof(raw) == sizeof(create));
  std::memcpy(&create, &raw, sizeof(raw));
  if (!create)
    return Creation::denied;
  PSID sid = nullptr;
  if (!ConvertStringSidToSidW(request_.frozen.target.sid.c_str(), &sid))
    return Creation::denied;
  SECURITY_DESCRIPTOR sd{};
  alignas(ACL) uint8_t bytes[512]{};
  auto acl = reinterpret_cast<PACL>(bytes);
  const bool secured =
      InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) &&
      SetSecurityDescriptorOwner(&sd, sid, FALSE) &&
      InitializeAcl(acl, sizeof(bytes), ACL_REVISION) &&
      AddAccessAllowedAceEx(acl, ACL_REVISION, 0, FILE_ALL_ACCESS, sid) &&
      SetSecurityDescriptorDacl(&sd, TRUE, acl, FALSE) &&
      SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
  // Compare the exact approved Owner/protected single-ACE DACL BEFORE create.
  LPWSTR text = nullptr;
  ULONG n = 0;
  bool approved = false;
  if (secured &&
      ConvertSecurityDescriptorToStringSecurityDescriptorW(
          &sd, SDDL_REVISION_1,
          OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &text, &n) &&
      n && n <= 32768) {
    CanonicalHashBuilder h;
    h.put_str("SHIROHA_L1_ARTIFACT_SECURITY_V1");
    for (ULONG i = 0; i < n - 1; ++i)
      h.put_u16_le(uint16_t(text[i]));
    approved = h.finalize_hex() == request_.root_security_sha256;
  }
  if (text)
    approved = (LocalFree(text) == nullptr) && approved;
  Creation result = Creation::denied;
  if (approved) {
    UNICODE_STRING name{};
    name.Buffer = leaf.data();
    name.Length = USHORT(leaf.size() * sizeof(wchar_t));
    name.MaximumLength = name.Length;
    OBJECT_ATTRIBUTES a{};
    a.Length = sizeof(a);
    a.RootDirectory = parents_.back().handle;
    a.ObjectName = &name;
    a.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
    a.SecurityDescriptor = &sd;
    IO_STATUS_BLOCK io{};
    const auto status = create(&root_.handle,
                               FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
                                   READ_CONTROL | SYNCHRONIZE,
                               &a, &io, nullptr, FILE_ATTRIBUTE_DIRECTORY,
                               FILE_SHARE_READ, FILE_CREATE,
                               FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT |
                                   FILE_SYNCHRONOUS_IO_NONALERT,
                               nullptr, 0);
    if (status == 0 && io.Status == 0 && io.Information == FILE_CREATED &&
        root_.handle && root_.handle != INVALID_HANDLE_VALUE) {
      root_created_ = true;
      result = Creation::created;
    } else if (status == LONG(0xC0000035u) &&
               (!root_.handle || root_.handle == INVALID_HANDLE_VALUE))
      result = Creation::exists;
    else
      result = Creation::unknown; // returned HANDLE, if any, stays owned here
  }
  const bool freed = LocalFree(sid) == nullptr;
  root_.owner_sid = request_.frozen.target.sid;
  root_.artifact_security_sha256 = request_.root_security_sha256;
  return freed ? result : Creation::unknown;
}
Observation WindowsPreparation::root() {
  Observation out;
  if (!root_created_)
    return out;
  // A new root has NO identity until this read succeeds. Never copy parent ID.
  if (!id(root_.identity).valid() &&
      !GetFileInformationByHandleEx(root_.handle, FileIdInfo, &root_.identity,
                                    sizeof(root_.identity)))
    return out;
  if (!inspect_e4_pin(root_, true, 0))
    return out;
  r1::Pin p;
  p.id = request_.root_id;
  p.owner = request_.frozen.manifest.pin_owner;
  p.object = id(root_.identity);
  p.parent = request_.parents.back().object;
  p.security_sha256 = request_.root_security_sha256;
  p.bytes_sha256 = metadata_hash(p.object);
  measure(root_, p, request_.frozen.target.scope.directory, out);
  return out;
}
bool WindowsPreparation::evidence_chain() {
  const auto paths =
      parent_paths(request_.evidence_directory + "\\evidence-controller.r2");
  if (evidence_parents_.size() != request_.evidence_parents.size() ||
      paths.size() != evidence_parents_.size())
    return false;
  for (size_t i = 0; i < paths.size(); ++i) {
    Observation o;
    if (!measure(evidence_parents_[i], request_.evidence_parents[i], paths[i],
                 o))
      return false;
  }
  return true;
}
bool WindowsPreparation::open_evidence() {
  return evidence_chain() && disk_.open_new();
}
bool WindowsPreparation::inspect_destination() {
  return evidence_chain() && disk_.inspect_destination();
}
r2::WriteStatus WindowsPreparation::write(const uint8_t *b, size_t n,
                                          size_t &done) {
  return disk_.write(b, n, done);
}
r2::WriteStatus WindowsPreparation::flush() { return disk_.flush(); }
Handoff WindowsPreparation::handoff(const r1::Pin &p,
                                    const std::string &request) {
  r2::WindowsPinSpec spec;
  spec.id = p.id;
  spec.owner = p.owner;
  spec.object = root_;
  spec.parent = parents_.back();
  spec.chain = parents_;
  spec.directory = true;
  return receiver_.retain(spec, request); // no process or custody dependency
}
bool WindowsPreparation::close_root() {
  if (root_close_attempted_ || !root_created_)
    return false;
  root_close_attempted_ = true;
  return CloseHandle(root_.handle) != FALSE;
}
bool WindowsPreparation::close_evidence() { return disk_.close_once(); }
} // namespace shiroha_l1_crypto::s1
