// Windows-only leaf candidates. COMPILE ONLY: never linked to a runnable
// target.
#include "diagnostics/l1_windows_operations.h"
#include "diagnostics/l1_temporary_handle.h"

#include <aclapi.h>
#include <psapi.h>
#include <sddl.h>
#include <winternl.h>

#include <cwchar>
#include <vector>

namespace shiroha_l1_crypto {
namespace {
struct LocalOwner {
  HLOCAL value = nullptr;
  ~LocalOwner() {
    if (value) LocalFree(value);
  }
};
bool close_token(uintptr_t value) noexcept {
  return CloseHandle(reinterpret_cast<HANDLE>(value))!=FALSE;
}
bool token_field(HANDLE token, TOKEN_INFORMATION_CLASS field,
                 std::vector<unsigned char> &bytes) noexcept {
  DWORD size = 0;
  GetTokenInformation(token, field, nullptr, 0, &size);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !size || size > 65536)
    return false;
  try {
    bytes.resize(size);
  } catch (...) {
    return false;
  }
  return GetTokenInformation(token, field, bytes.data(), size, &size) != FALSE;
}
}  // namespace

bool inspect_exact_token(HANDLE process, const std::wstring &sid) noexcept {
  LocalOwner expected;
  if (!ConvertStringSidToSidW(sid.c_str(), &expected.value))
    return false;
  HANDLE token_value = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token_value))
    return false;
  TemporaryHandle token(TemporaryOwner::token_validator,
                        reinterpret_cast<uintptr_t>(token_value), close_token);
  const bool checked = [&]() {
    std::vector<unsigned char> bytes;
    if (!token_field(token_value, TokenUser, bytes) ||
        !EqualSid(reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid,
                  expected.value))
      return false;
    if (!token_field(token_value, TokenElevation, bytes) ||
        reinterpret_cast<TOKEN_ELEVATION *>(bytes.data())->TokenIsElevated)
      return false;
    if (!token_field(token_value, TokenType, bytes) ||
        *reinterpret_cast<TOKEN_TYPE *>(bytes.data()) != TokenPrimary)
      return false;
    if (!token_field(token_value, TokenIntegrityLevel, bytes))
      return false;
    auto label =
        reinterpret_cast<TOKEN_MANDATORY_LABEL *>(bytes.data())->Label.Sid;
    if (!IsValidSid(label) || *GetSidSubAuthorityCount(label) == 0 ||
        *GetSidSubAuthority(label, *GetSidSubAuthorityCount(label) - 1) !=
            SECURITY_MANDATORY_MEDIUM_RID)
      return false;
    if (IsTokenRestricted(token_value))
      return false;
    if (!token_field(token_value, TokenPrivileges, bytes))
      return false;
    const auto privileges = reinterpret_cast<TOKEN_PRIVILEGES *>(bytes.data());
    LUID traverse{};
    if (!LookupPrivilegeValueW(nullptr, SE_CHANGE_NOTIFY_NAME, &traverse))
      return false;
    for (DWORD i = 0; i < privileges->PrivilegeCount; ++i) {
      const auto &p = privileges->Privileges[i];
      if ((p.Attributes & SE_PRIVILEGE_ENABLED) &&
          (p.Luid.LowPart != traverse.LowPart ||
           p.Luid.HighPart != traverse.HighPart))
        return false;
    }
    return true;
  }();
  const bool closed = token.close_as(TemporaryOwner::token_validator);
  return checked && closed;
}

bool inspect_pinned_object(const WindowsObjectPin &pin) noexcept {
  if (!pin.handle || pin.handle == INVALID_HANDLE_VALUE ||
      pin.owner_sid.empty())
    return false;
  FILE_ID_INFO id{};
  FILE_ATTRIBUTE_TAG_INFO tag{};
  FILE_STANDARD_INFO info{};
  wchar_t fs[16]{};
  wchar_t final_name[1024]{};
  const DWORD length = GetFinalPathNameByHandleW(
      pin.handle, final_name, 1024, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!length || length >= 1024 ||
      std::wcsncmp(final_name, L"\\\\?\\C:\\", 7) != 0 ||
      !GetVolumeInformationByHandleW(pin.handle, nullptr, 0, nullptr, nullptr,
                                     nullptr, fs, 16) ||
      std::wcscmp(fs, L"NTFS") ||
      !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &id, sizeof(id)) ||
      id.VolumeSerialNumber != pin.identity.VolumeSerialNumber ||
      std::memcmp(&id.FileId, &pin.identity.FileId, sizeof(id.FileId)) ||
      !GetFileInformationByHandleEx(pin.handle, FileAttributeTagInfo, &tag,
                                    sizeof(tag)) ||
      (tag.FileAttributes &
       (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
      !GetFileInformationByHandleEx(pin.handle, FileStandardInfo, &info,
                                    sizeof(info)) ||
      info.DeletePending || info.NumberOfLinks != 1 ||
      info.EndOfFile.QuadPart != 1)
    return false;
  LocalOwner expected, descriptor;
  PSID owner = nullptr;
  PACL dacl = nullptr;
  if (!ConvertStringSidToSidW(pin.owner_sid.c_str(), &expected.value) ||
      GetSecurityInfo(pin.handle, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      &owner, nullptr, &dacl, nullptr,
                      reinterpret_cast<PSECURITY_DESCRIPTOR *>(
                          &descriptor.value)) != ERROR_SUCCESS ||
      !owner || !EqualSid(owner, expected.value) || !dacl || !IsValidAcl(dacl))
    return false;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorControl(descriptor.value, &control, &revision) ||
      !(control & SE_DACL_PROTECTED) || dacl->AceCount != 1)
    return false;
  void *raw_ace = nullptr;
  if (!GetAce(dacl, 0, &raw_ace)) return false;
  const auto ace = static_cast<ACCESS_ALLOWED_ACE *>(raw_ace);
  // Deliberately narrow candidate ACL: one explicit owner-only ACE. No repair.
  return ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
         ace->Header.AceFlags == 0 &&
         EqualSid(&ace->SidStart, expected.value) &&
         ace->Mask == FILE_ALL_ACCESS;
}

ConsumptionRecord burn_pinned_grant(const WindowsObjectPin &pin) noexcept {
  ConsumptionRecord result;
  // No grant creation/reissuance/delete path. Identity must come from the
  // separately trusted issuer, never from bytes copied beside the object.
  if (!inspect_pinned_object(pin)) {
    result.state = GrantState::kRejected;
    return result;
  }
  OVERLAPPED range{};
  if (!LockFileEx(pin.handle,
                  LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0,
                  MAXDWORD, MAXDWORD, &range)) {
    result.unknown = true;
    result.state = GrantState::kUnknown;
    return result;
  }
  // A locked handle is not a durability or issuance proof. Even a successful
  // write+Flush cannot mint a permit without a durable independent request
  // journal. The integrated backend below stops BEFORE calling this leaf.
  LARGE_INTEGER zero{};
  unsigned char marker = 0;
  DWORD count = 0;
  const bool issued = inspect_pinned_object(pin) &&
                      SetFilePointerEx(pin.handle, zero, nullptr, FILE_BEGIN) &&
                      ReadFile(pin.handle, &marker, 1, &count, nullptr) &&
                      count == 1 && marker == 1;
  if (issued) {
    result.request_started = true;
    marker = 2;  // Irreversible candidate burn, never rewritten to issued.
    if (SetFilePointerEx(pin.handle, zero, nullptr, FILE_BEGIN) &&
        WriteFile(pin.handle, &marker, 1, &count, nullptr) && count == 1)
      FlushFileBuffers(
          pin.handle);  // Result never interpreted as durable permit.
  }
  UnlockFileEx(pin.handle, 0, MAXDWORD, MAXDWORD, &range);
  result.unknown = true;
  result.state = GrantState::kUnknown;
  return result;
}

bool observe_process(HANDLE process, ResourceSample &sample, bool &exited,
                     bool &normal_exit) noexcept {
  PROCESS_MEMORY_COUNTERS memory{};
  memory.cb = sizeof(memory);
  DWORD handles = 0, code = 0;
  const DWORD wait = WaitForSingleObject(process, 0);
  if ((wait != WAIT_OBJECT_0 && wait != WAIT_TIMEOUT) ||
      !GetProcessMemoryInfo(process, &memory, sizeof(memory)) ||
      !GetProcessHandleCount(process, &handles))
    return false;
  exited = wait == WAIT_OBJECT_0;
  normal_exit = false;
  if (exited) {
    if (!GetExitCodeProcess(process, &code)) return false;
    normal_exit =
        code == 0;  // Necessary observation only, NEVER a PASS verdict.
  }
  sample.observed_at_ms = GetTickCount64();
  sample.peak_working_set = memory.PeakWorkingSetSize;
  sample.peak_commit = memory.PeakPagefileUsage;
  sample.handles = handles;
  return true;
}

bool Win32AdmissionOperations::trusted_approval(
    const WindowsBinding &) noexcept {
  // STOP: signer/verification key/trust boundary/custody or another
  // independently authenticated approval channel has NOT been frozen. No
  // generated test key.
  return false;
}
bool Win32AdmissionOperations::inspect(WindowsBinding &) noexcept {
  return false;
}
bool Win32AdmissionOperations::now(uint64_t &at) noexcept {
  at = GetTickCount64();
  return true;
}
ConsumptionRecord Win32AdmissionOperations::consume_once(const WindowsBinding &,
                                                         uint64_t) noexcept {
  // STOP before file/lock access: durable request-start journal, issuance and
  // parent/artifact/device pins have not been supplied by a trusted authority.
  ConsumptionRecord result;
  result.state = GrantState::kUnknown;
  result.unknown = true;
  return result;
}
WorkerState Win32AdmissionOperations::start_worker(
    const WindowsBinding &) noexcept {
  // STOP: no approved process/IPC/handle/environment/Job plan. No
  // CreateProcess, ResumeThread, kill-on-timeout or recovery fallback.
  return WorkerState::kStartFailed;
}
WorkerObservation Win32AdmissionOperations::observe_worker() noexcept {
  return {};
}

bool inspect_e4_pin(const WindowsObjectPin &pin, bool directory,
                    uint64_t length) noexcept {
  FILE_ID_INFO id{};
  FILE_ATTRIBUTE_TAG_INFO tag{};
  FILE_STANDARD_INFO info{};
  wchar_t fs[16]{}, name[1024]{};
  DWORD size = GetFinalPathNameByHandleW(
      pin.handle, name, 1024, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!size || size >= 1024 || std::wcsncmp(name, L"\\\\?\\C:\\", 7) ||
      !GetVolumeInformationByHandleW(pin.handle, nullptr, 0, nullptr, nullptr,
                                     nullptr, fs, 16) ||
      std::wcscmp(fs, L"NTFS") ||
      !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &id, sizeof(id)) ||
      id.VolumeSerialNumber != pin.identity.VolumeSerialNumber ||
      std::memcmp(&id.FileId, &pin.identity.FileId, 16) ||
      !id.VolumeSerialNumber || e4::zero(id.FileId.Identifier, 16) ||
      !GetFileInformationByHandleEx(pin.handle, FileAttributeTagInfo, &tag,
                                    sizeof(tag)) ||
      (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      bool(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory ||
      !GetFileInformationByHandleEx(pin.handle, FileStandardInfo, &info,
                                    sizeof(info)) ||
      info.DeletePending ||
      (!directory && (info.NumberOfLinks != 1 ||
                      uint64_t(info.EndOfFile.QuadPart) != length)))
    return false;
  LocalOwner expected, descriptor;
  PSID owner = nullptr;
  PACL acl = nullptr;
  if (!ConvertStringSidToSidW(pin.owner_sid.c_str(), &expected.value) ||
      GetSecurityInfo(pin.handle, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      &owner, nullptr, &acl, nullptr,
                      reinterpret_cast<PSECURITY_DESCRIPTOR *>(
                          &descriptor.value)) != ERROR_SUCCESS ||
      !owner || !EqualSid(owner, expected.value) || !acl || !IsValidAcl(acl) ||
      acl->AceCount != 1)
    return false;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  void *raw = nullptr;
  if (!GetSecurityDescriptorControl(descriptor.value, &control, &revision) ||
      !(control & SE_DACL_PROTECTED) || !GetAce(acl, 0, &raw))
    return false;
  auto ace = static_cast<ACCESS_ALLOWED_ACE *>(raw);
  return ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
         !ace->Header.AceFlags && ace->Mask == FILE_ALL_ACCESS &&
         EqualSid(&ace->SidStart, expected.value);
}
bool inspect_e4_parent_chain(
    const std::vector<WindowsObjectPin> &chain) noexcept {
  // Frozen accepted ancestor plus immediate controlled descendants. No scan,
  // path reopen or guessed current identity; caller retains all parent handles.
  if (chain.size() < 2 || chain.size() > 16)
    return false;
  try {
    std::wstring previous;
    for (size_t i = 0; i < chain.size(); ++i) {
      const auto &pin = chain[i];
      FILE_ID_INFO identity{};
      FILE_ATTRIBUTE_TAG_INFO tag{};
      wchar_t name[32768]{}, fs[16]{};
      DWORD length = GetFinalPathNameByHandleW(
          pin.handle, name, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
      if (!length || length >= 32768 || std::wcsncmp(name, L"\\\\?\\C:\\", 7) ||
          !GetVolumeInformationByHandleW(pin.handle, nullptr, 0, nullptr,
                                         nullptr, nullptr, fs, 16) ||
          std::wcscmp(fs, L"NTFS") ||
          !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &identity,
                                        sizeof(identity)) ||
          identity.VolumeSerialNumber != pin.identity.VolumeSerialNumber ||
          std::memcmp(&identity.FileId, &pin.identity.FileId, 16) ||
          !identity.VolumeSerialNumber ||
          e4::zero(identity.FileId.Identifier, 16) ||
          !GetFileInformationByHandleEx(pin.handle, FileAttributeTagInfo, &tag,
                                        sizeof(tag)) ||
          !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
          (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return false;
      std::wstring current(name, length);
      if (i) {
        std::wstring prefix = previous;
        if (prefix.back() != L'\\')
          prefix += L'\\';
        if (current.size() <= prefix.size() ||
            current.compare(0, prefix.size(), prefix) ||
            current.find(L'\\', prefix.size()) != std::wstring::npos ||
            !inspect_e4_pin(pin, true, 0))
          return false;
      } else {
        // OS ancestor Owner/DACL are frozen as-is, never repaired.
        LocalOwner descriptor, sddl;
        ULONG size = 0;
        if (!hex_digest(pin.artifact_security_sha256, 64) ||
            GetSecurityInfo(
                pin.handle, SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, nullptr,
                nullptr, nullptr, nullptr,
                reinterpret_cast<PSECURITY_DESCRIPTOR *>(&descriptor.value)) !=
                ERROR_SUCCESS ||
            !ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor.value, SDDL_REVISION_1,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                reinterpret_cast<LPWSTR *>(&sddl.value), &size) ||
            !size || size > 32768)
          return false;
        auto text = static_cast<const wchar_t *>(sddl.value);
        CanonicalHashBuilder security;
        security.put_str("SHIROHA_L1_ARTIFACT_SECURITY_V1");
        for (ULONG k = 0; k < size - 1; ++k)
          security.put_u16_le(uint16_t(text[k]));
        if (security.finalize_hex() != pin.artifact_security_sha256)
          return false;
      }
      for (size_t earlier = 0; earlier < i; ++earlier)
        if (!std::memcmp(&chain[earlier].identity.FileId, &pin.identity.FileId,
                         16))
          return false;
      previous = std::move(current);
    }
    return true;
  } catch (...) {
    return false;
  }
}
bool create_e4_record(const WindowsObjectPin &parent, const wchar_t *fixed_name,
                      uint64_t length, HANDLE &owned) noexcept {
  owned = INVALID_HANDLE_VALUE;
  if (!fixed_name || !inspect_e4_pin(parent, true, 0) ||
      (std::wcscmp(fixed_name, L"approval.receipt") &&
       std::wcscmp(fixed_name, L"grant.bin") &&
       std::wcscmp(fixed_name, L"request.journal")) ||
      (length != 1 && length != 128 && length != 256))
    return false;
  // FILE_CREATE under pinned RootDirectory is NT's CREATE_NEW equivalent.
  auto module = GetModuleHandleW(L"ntdll.dll");
  auto symbol = module ? GetProcAddress(module, "NtCreateFile") : nullptr;
  decltype(&NtCreateFile) create = nullptr;
  static_assert(sizeof(create) == sizeof(symbol), "function pointer");
  std::memcpy(&create, &symbol, sizeof(create));
  if (!create)
    return false;
  LocalOwner sid;
  if (!ConvertStringSidToSidW(parent.owner_sid.c_str(), &sid.value))
    return false;
  SECURITY_DESCRIPTOR sd{};
  alignas(ACL) uint8_t storage[512]{};
  auto acl = reinterpret_cast<PACL>(storage);
  if (!InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) ||
      !SetSecurityDescriptorOwner(&sd, sid.value, FALSE) ||
      !InitializeAcl(acl, sizeof(storage), ACL_REVISION) ||
      !AddAccessAllowedAceEx(acl, ACL_REVISION, 0, FILE_ALL_ACCESS,
                             sid.value) ||
      !SetSecurityDescriptorDacl(&sd, TRUE, acl, FALSE) ||
      !SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED))
    return false;
  UNICODE_STRING name{};
  name.Buffer = const_cast<PWSTR>(fixed_name);
  name.Length = USHORT(std::wcslen(fixed_name) * sizeof(wchar_t));
  name.MaximumLength = name.Length;
  OBJECT_ATTRIBUTES a{};
  a.Length = sizeof(a);
  a.RootDirectory = parent.handle;
  a.ObjectName = &name;
  a.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
  a.SecurityDescriptor = &sd;
  IO_STATUS_BLOCK io{};
  LARGE_INTEGER allocation{};
  allocation.QuadPart = LONGLONG(length);
  HANDLE h = INVALID_HANDLE_VALUE;
  auto result = create(
      &h, GENERIC_READ | GENERIC_WRITE | READ_CONTROL | SYNCHRONIZE, &a, &io,
      &allocation, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT |
          FILE_SYNCHRONOUS_IO_NONALERT,
      nullptr, 0);
  if (result != 0 || io.Status != 0 || io.Information != FILE_CREATED) {
    if (h != INVALID_HANDLE_VALUE && h)
      CloseHandle(h);
    return false;
  }
  owned = h;
  return true;
}
bool write_e4_record(const WindowsObjectPin &pin, const uint8_t *bytes,
                     DWORD length) noexcept {
  // Caller must have validated the newly created empty pin before first write;
  // updates require exact size. No truncation/replace/delete fallback.
  FILE_STANDARD_INFO info{};
  FILE_ID_INFO id{};
  if (!bytes || !length || length > 256 ||
      !GetFileInformationByHandleEx(pin.handle, FileStandardInfo, &info,
                                    sizeof(info)) ||
      (info.EndOfFile.QuadPart != 0 && info.EndOfFile.QuadPart != length) ||
      !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &id, sizeof(id)) ||
      id.VolumeSerialNumber != pin.identity.VolumeSerialNumber ||
      std::memcmp(&id.FileId, &pin.identity.FileId, 16) ||
      !inspect_e4_pin(pin, false, uint64_t(info.EndOfFile.QuadPart)))
    return false;
  LARGE_INTEGER start{};
  DWORD written = 0;
  return SetFilePointerEx(pin.handle, start, nullptr, FILE_BEGIN) &&
         WriteFile(pin.handle, bytes, length, &written, nullptr) &&
         written == length && FlushFileBuffers(pin.handle) &&
         inspect_e4_pin(pin, false, length);
}
bool read_e4_clock(e4::ClockReading &out,
                   uint64_t controller_session) noexcept {
  FILETIME wall{};
  GetSystemTimePreciseAsFileTime(&wall);
  ULARGE_INTEGER ticks{};
  ticks.LowPart = wall.dwLowDateTime;
  ticks.HighPart = wall.dwHighDateTime;
  constexpr uint64_t epoch = 116444736000000000ULL;
  if (!controller_session || ticks.QuadPart < epoch)
    return false;
  // Session is process-lifetime issuer identity, not an asserted Windows Boot
  // ID. Reconstructed controllers cannot resume issuance even in the same OS
  // boot.
  out = {(ticks.QuadPart - epoch) / 10000, GetTickCount64(), controller_session,
         true};
  return true;
}
bool create_e4_suspended(const GrantTarget &target,
                         e4::ClockReading launch_clock,
                         const WindowsObjectPin &image,
                         const std::string &image_sha256,
                         const WindowsObjectPin &directory, HANDLE *ipc_handles,
                         size_t count,
                         SuspendedWorkerCustody &custody) noexcept {
  if (!target.valid() || target.exe_sha256 != image_sha256 || custody.created ||
      custody.resume_attempted || !inspect_e4_pin(directory, true, 0) ||
      !verify_e4_artifact(image, image_sha256) || !ipc_handles || count != 2)
    return false;
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
  if (!bytes || bytes > 65536)
    return false;
  try {
    wchar_t frozen_exe[32768]{}, fixed_directory[32768]{}, windows[32768]{};
    DWORD exe_size =
        GetFinalPathNameByHandleW(image.handle, frozen_exe, 32768,
                                  FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    DWORD directory_size =
        GetFinalPathNameByHandleW(directory.handle, fixed_directory, 32768,
                                  FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    UINT windows_size = GetWindowsDirectoryW(windows, 32768);
    if (!exe_size || exe_size >= 32768 || !directory_size ||
        directory_size >= 32768 || !windows_size || windows_size >= 32768)
      return false;
    std::wstring command =
        L"l1-worker " +
        std::to_wstring(reinterpret_cast<uintptr_t>(ipc_handles[0])) + L" " +
        std::to_wstring(reinterpret_cast<uintptr_t>(ipc_handles[1]));
    std::wstring environment = L"SystemRoot=" + std::wstring(windows);
    environment.push_back(0);
    environment += L"WINDIR=" + std::wstring(windows);
    environment.push_back(0);
    environment.push_back(0);
    for (size_t i = 0; i < count; ++i) {
      DWORD flags = 0;
      if (!GetHandleInformation(ipc_handles[i], &flags) ||
          !(flags & HANDLE_FLAG_INHERIT) ||
          GetFileType(ipc_handles[i]) != FILE_TYPE_PIPE)
        return false;
    }
    std::vector<uint8_t> buffer(bytes);
    STARTUPINFOEXW si{};
    si.StartupInfo.cb = sizeof(si);
    si.lpAttributeList =
        reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(buffer.data());
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &bytes))
      return false;
    bool configured =
        UpdateProcThreadAttribute(
            si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            ipc_handles, count * sizeof(HANDLE), nullptr, nullptr) != FALSE;
    e4::ClockReading fresh{};
    e4::ClockValidator clock;
    bool timely = clock.accept(launch_clock) &&
                  read_e4_clock(fresh, launch_clock.session) &&
                  clock.accept(fresh) && e4::window(target, fresh) &&
                  fresh.mono - launch_clock.mono < 30000;
    bool created =
        configured && timely &&
        CreateProcessW(frozen_exe, command.data(), nullptr, nullptr, TRUE,
                       CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT |
                           CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                       environment.data(), fixed_directory, &si.StartupInfo,
                       &custody.process) != FALSE;
    DeleteProcThreadAttributeList(si.lpAttributeList);
    custody.created = created;
    return created;
  } catch (...) {
    return false;
  }
}
bool inspect_e4_image(HANDLE process, const WindowsObjectPin &image) noexcept {
  wchar_t actual[32768]{};
  DWORD n = 32768;
  wchar_t pinned[32768]{};
  DWORD size = GetFinalPathNameByHandleW(
      image.handle, pinned, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!size || size >= 32768 ||
      !QueryFullProcessImageNameW(process, 0, actual, &n))
    return false;
  // A matching path alone is not File ID proof: the caller retains a read-only
  // image pin denying write/delete sharing and separately verifies its digest.
  const wchar_t *normalized =
      std::wcsncmp(pinned, L"\\\\?\\", 4) == 0 ? pinned + 4 : pinned;
  if (_wcsicmp(normalized, actual) != 0)
    return false;
  HANDLE actual_file =
      CreateFileW(actual, GENERIC_READ | READ_CONTROL, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (actual_file == INVALID_HANDLE_VALUE)
    return false;
  TemporaryHandle image_owner(TemporaryOwner::image_reader,
      reinterpret_cast<uintptr_t>(actual_file), close_token);
  FILE_ID_INFO actual_id{};
  bool same =
      GetFileInformationByHandleEx(actual_file, FileIdInfo, &actual_id,
                                   sizeof(actual_id)) &&
      actual_id.VolumeSerialNumber == image.identity.VolumeSerialNumber &&
      std::memcmp(&actual_id.FileId, &image.identity.FileId, 16) == 0;
  bool closed = image_owner.close_as(TemporaryOwner::image_reader);
  return same && closed;
}
bool verify_e4_artifact(const WindowsObjectPin &pin,
                        const std::string &expected_sha256) noexcept {
  if (!hex_digest(expected_sha256, 64) ||
      !hex_digest(pin.artifact_security_sha256, 64))
    return false;
  FILE_STANDARD_INFO info{};
  FILE_ID_INFO identity{};
  FILE_ATTRIBUTE_TAG_INFO tag{};
  if (!GetFileInformationByHandleEx(pin.handle, FileStandardInfo, &info,
                                    sizeof(info)) ||
      info.EndOfFile.QuadPart <= 0 || info.EndOfFile.QuadPart > 67108864 ||
      info.DeletePending ||
      !GetFileInformationByHandleEx(pin.handle, FileIdInfo, &identity,
                                    sizeof(identity)) ||
      identity.VolumeSerialNumber != pin.identity.VolumeSerialNumber ||
      std::memcmp(&identity.FileId, &pin.identity.FileId, 16) ||
      !GetFileInformationByHandleEx(pin.handle, FileAttributeTagInfo, &tag,
                                    sizeof(tag)) ||
      (tag.FileAttributes &
       (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)))
    return false;
  try {
    LocalOwner descriptor, sddl;
    ULONG length = 0;
    if (GetSecurityInfo(pin.handle, SE_FILE_OBJECT,
                        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                        nullptr, nullptr, nullptr, nullptr,
                        reinterpret_cast<PSECURITY_DESCRIPTOR *>(
                            &descriptor.value)) != ERROR_SUCCESS ||
        !ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor.value, SDDL_REVISION_1,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            reinterpret_cast<LPWSTR *>(&sddl.value), &length) ||
        !length || length > 32768)
      return false;
    auto text = static_cast<const wchar_t *>(sddl.value);
    CanonicalHashBuilder security;
    security.put_str("SHIROHA_L1_ARTIFACT_SECURITY_V1");
    for (ULONG i = 0; i < length - 1; ++i)
      security.put_u16_le(uint16_t(text[i]));
    if (security.finalize_hex() != pin.artifact_security_sha256)
      return false;
    std::vector<uint8_t> bytes(size_t(info.EndOfFile.QuadPart));
    LARGE_INTEGER start{};
    if (!SetFilePointerEx(pin.handle, start, nullptr, FILE_BEGIN))
      return false;
    size_t at = 0;
    while (at < bytes.size()) {
      DWORD read = 0,
            requested = DWORD((std::min)(bytes.size() - at, size_t(65536)));
      if (!ReadFile(pin.handle, bytes.data() + at, requested, &read, nullptr) ||
          !read || read > requested)
        return false;
      at += read;
    }
    auto hash = e4::digest(bytes.data(), bytes.size());
    return encode_hex_bytes(hash.data(), hash.size()) == expected_sha256;
  } catch (...) {
    return false;
  }
}
bool inspect_e4_dependencies(HANDLE process,
                             const std::vector<WindowsObjectPin> &pins,
                             const std::vector<std::string> &hashes) noexcept {
  // Check again after loader initialization/HELLO and BEFORE work admission.
  // This bounds the module snapshot, not future arbitrary LoadLibrary activity;
  // Worker source/import guards prohibit such dynamic loading.
  if (pins.empty() || pins.size() > 128 || pins.size() != hashes.size())
    return false;
  HMODULE modules[128]{};
  DWORD needed = 0;
  if (!EnumProcessModulesEx(process, modules, sizeof(modules), &needed,
                            LIST_MODULES_ALL) ||
      needed != pins.size() * sizeof(HMODULE))
    return false;
  std::array<bool, 128> seen{};
  for (size_t i = 0; i < pins.size(); ++i) {
    wchar_t name[32768]{};
    DWORD size = GetModuleFileNameExW(process, modules[i], name, 32768);
    if (!size || size >= 32768)
      return false;
    HANDLE file =
        CreateFileW(name, GENERIC_READ | READ_CONTROL, FILE_SHARE_READ, nullptr,
                    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE)
      return false;
    FILE_ID_INFO identity{};
    bool known = false;
    if (GetFileInformationByHandleEx(file, FileIdInfo, &identity,
                                     sizeof(identity)))
      for (size_t j = 0; j < pins.size(); ++j) {
        if (identity.VolumeSerialNumber ==
                pins[j].identity.VolumeSerialNumber &&
            !std::memcmp(&identity.FileId, &pins[j].identity.FileId, 16) &&
            !seen[j]) {
          known = verify_e4_artifact(pins[j], hashes[j]);
          seen[j] = known;
          break;
        }
      }
    bool closed = CloseHandle(file) != FALSE;
    if (!known || !closed)
      return false;
  }
  return true;
}
bool create_e4_pipe_pair(HANDLE (&ends)[4]) noexcept {
  for (auto h : ends)
    if (h && h != INVALID_HANDLE_VALUE)
      return false;
  SECURITY_ATTRIBUTES attrs{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  // [0] controller read, [1] worker write; [2] worker read, [3] controller
  // write. Handles [1,2] alone go in the child's explicit handle list.
  // Controller ends do not inherit. On partial failure caller retains created
  // handles for one close.
  return CreatePipe(&ends[0], &ends[1], &attrs, 4096) &&
         CreatePipe(&ends[2], &ends[3], &attrs, 4096) &&
         SetHandleInformation(ends[0], HANDLE_FLAG_INHERIT, 0) &&
         SetHandleInformation(ends[3], HANDLE_FLAG_INHERIT, 0);
}
e4::Chunk read_e4_pipe_chunk(HANDLE pipe, uint8_t *out, size_t capacity,
                             uint64_t deadline_mono) noexcept {
  if (GetTickCount64() >= deadline_mono)
    return {0, false, false, true};
  if (!out || !capacity || capacity > 64)
    return {0, false, true, false};
  DWORD available = 0;
  if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
    return GetLastError() == ERROR_BROKEN_PIPE
               ? e4::Chunk{0, true, false, false}
               : e4::Chunk{0, false, true, false};
  }
  // No waiting/retry loop. A caller may schedule another bounded poll, but this
  // leaf makes no hard guarantee that a pathological kernel call is
  // cancellable.
  if (!available)
    return {0, false, false, true};
  DWORD read = 0;
  DWORD requested = DWORD((std::min)(capacity, size_t(available)));
  if (!ReadFile(pipe, out, requested, &read, nullptr))
    return {0, false, true, false};
  if (GetTickCount64() >= deadline_mono)
    return {0, false, false, true};
  return {read, false, false, false};
}
bool resume_e4_once(SuspendedWorkerCustody &c) noexcept {
  if (!c.created || c.resume_attempted || !c.token_checked ||
      !c.image_checked || !c.dependencies_checked || !c.handles_checked)
    return false;
  c.resume_attempted = true;
  const DWORD count = ResumeThread(c.process.hThread);
  c.resume_unknown = count != 1;
  return count == 1;
}
bool close_e4_observed_exit(SuspendedWorkerCustody &c) noexcept {
  if (!c.created || c.close_attempted ||
      WaitForSingleObject(c.process.hProcess, 0) != WAIT_OBJECT_0)
    return false;
  c.close_attempted = true;
  bool thread_closed = CloseHandle(c.process.hThread) != FALSE;
  if (thread_closed)
    c.process.hThread = nullptr;
  bool process_closed = CloseHandle(c.process.hProcess) != FALSE;
  if (process_closed)
    c.process.hProcess = nullptr;
  return thread_closed && process_closed;
}
bool E4WindowsGrantIo::principal(const std::wstring &sid) {
  return sid == parent_.owner_sid &&
         inspect_exact_token(GetCurrentProcess(), sid) &&
         inspect_e4_parent_chain(chain_) &&
         chain_.back().identity.VolumeSerialNumber ==
             parent_.identity.VolumeSerialNumber &&
         std::memcmp(&chain_.back().identity.FileId, &parent_.identity.FileId,
                     16) == 0;
}
e4::IoResult E4WindowsGrantIo::issue_new(const e4::Receipt &bytes,
                                         BatchObjectPins &pins) {
  if (issue_attempted_)
    return e4::IoResult::denied;
  issue_attempted_ = true;
  receipt_.owner_sid = grant_.owner_sid = parent_.owner_sid;
  if (!create_e4_record(parent_, L"approval.receipt", 256, receipt_.handle) ||
      !GetFileInformationByHandleEx(receipt_.handle, FileIdInfo,
                                    &receipt_.identity,
                                    sizeof(receipt_.identity)) ||
      !write_e4_record(receipt_, bytes.data(), 256) ||
      !create_e4_record(parent_, L"grant.bin", 1, grant_.handle) ||
      !GetFileInformationByHandleEx(grant_.handle, FileIdInfo, &grant_.identity,
                                    sizeof(grant_.identity)))
    return e4::IoResult::unknown;
  const uint8_t issued = 1;
  if (!write_e4_record(grant_, &issued, 1))
    return e4::IoResult::unknown;
  auto assign = [](const WindowsObjectPin &p, ObjectIdentityPin &v) {
    v.volume_serial = p.identity.VolumeSerialNumber;
    std::copy_n(p.identity.FileId.Identifier, 16, v.file_id.begin());
  };
  assign(parent_, pins.dir_pin);
  assign(receipt_, pins.receipt_pin);
  assign(grant_, pins.grant_pin);
  return pins.valid() && inspect(pins) ? e4::IoResult::ok
                                       : e4::IoResult::unknown;
}
bool E4WindowsGrantIo::inspect(const BatchObjectPins &pins) {
  if (!principal(parent_.owner_sid))
    return false;
  auto same = [](const WindowsObjectPin &p, const ObjectIdentityPin &v) {
    return p.identity.VolumeSerialNumber == v.volume_serial &&
           std::equal(v.file_id.begin(), v.file_id.end(),
                      p.identity.FileId.Identifier);
  };
  return pins.valid() && same(parent_, pins.dir_pin) &&
         same(receipt_, pins.receipt_pin) && same(grant_, pins.grant_pin) &&
         inspect_e4_pin(parent_, true, 0) &&
         inspect_e4_pin(receipt_, false, 256) &&
         inspect_e4_pin(grant_, false, 1);
}
e4::IoResult E4WindowsGrantIo::request_new(const e4::Journal &bytes) {
  if (request_attempted_)
    return e4::IoResult::denied;
  request_attempted_ = true;
  journal_.owner_sid = parent_.owner_sid;
  if (!e4::valid_journal(bytes) || bytes[6] != 1 ||
      !create_e4_record(parent_, L"request.journal", 128, journal_.handle) ||
      !GetFileInformationByHandleEx(journal_.handle, FileIdInfo,
                                    &journal_.identity,
                                    sizeof(journal_.identity)) ||
      !write_e4_record(journal_, bytes.data(), 128))
    return e4::IoResult::unknown;
  return e4::IoResult::ok;
}
e4::IoResult E4WindowsGrantIo::burn_issued() {
  if (!request_attempted_ || !inspect_e4_pin(journal_, false, 128) ||
      !inspect_e4_pin(grant_, false, 1))
    return e4::IoResult::unknown;
  OVERLAPPED range{};
  if (!LockFileEx(grant_.handle,
                  LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0,
                  MAXDWORD, MAXDWORD, &range))
    return e4::IoResult::unknown;
  LARGE_INTEGER zero{};
  uint8_t marker = 0;
  DWORD count = 0;
  bool matched = SetFilePointerEx(grant_.handle, zero, nullptr, FILE_BEGIN) &&
                 ReadFile(grant_.handle, &marker, 1, &count, nullptr) &&
                 count == 1 && marker == 1;
  marker = 2;
  bool burned = matched && write_e4_record(grant_, &marker, 1);
  bool unlocked =
      UnlockFileEx(grant_.handle, 0, MAXDWORD, MAXDWORD, &range) != FALSE;
  return burned && unlocked ? e4::IoResult::ok : e4::IoResult::unknown;
}
e4::IoResult E4WindowsGrantIo::update_request(const e4::Journal &bytes) {
  if (!request_attempted_ || !e4::valid_journal(bytes) ||
      !write_e4_record(journal_, bytes.data(), 128))
    return e4::IoResult::unknown;
  return e4::IoResult::ok;
}
bool E4WindowsGrantIo::close_owned_records() noexcept {
  if (close_attempted_) return close_complete_;
  close_attempted_ = true;
  bool ok = true;
  for (auto pin : {&journal_, &grant_, &receipt_}) {
    if (pin->handle && pin->handle != INVALID_HANDLE_VALUE) {
      if (CloseHandle(pin->handle)) pin->handle = INVALID_HANDLE_VALUE;
      else ok = false;
    }
  }
  return close_complete_ = ok;
}
bool show_e4_approval(const e4::ApprovalPromptModel &p,
                      e4::ApprovalUiResponse &response) noexcept {
  // UI leaf is intentionally independent of grant issuance. The controller
  // verifies returned text and all fields again; UI is not strong
  // authentication. A fixed summary dialog followed by a six-character edit
  // dialog is prepared below with an in-memory dialog template; no production
  // App UI is involved.
  response = {};
  try {
    const std::string &text = p.summary;
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                     int(text.size()), nullptr, 0);
    if (length <= 0)
      return false;
    std::wstring wide(size_t(length), L' ');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                        int(text.size()), wide.data(), length);
    // This first step alone never returns an approving response. Typed suffix
    // is handled by the dialog procedure; caller supplies no prefilled input.
    if (MessageBoxW(nullptr, wide.c_str(), L"L1-CRYPTO target review",
                    MB_OKCANCEL | MB_ICONWARNING) != IDOK) {
      response.cancelled = true;
      return false;
    }
    struct DialogData {
      const e4::ApprovalPromptModel *prompt;
      e4::ApprovalUiResponse *response;
    } data{&p, &response};
    alignas(DWORD) uint8_t raw[128]{};
    auto dialog = reinterpret_cast<DLGTEMPLATE *>(raw);
    dialog->style = WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME;
    dialog->cx = 260;
    dialog->cy = 100;
    auto procedure =
        +[](HWND w, UINT message, WPARAM wp, LPARAM lp) -> INT_PTR {
      if (message == WM_INITDIALOG) {
        auto d = reinterpret_cast<DialogData *>(lp);
        SetWindowLongPtrW(w, DWLP_USER, lp);
        std::wstring challenge(d->prompt->suffix.begin(),
                               d->prompt->suffix.end());
        challenge = L"Type current suffix: " + challenge;
        CreateWindowExW(0, L"STATIC", challenge.c_str(), WS_CHILD | WS_VISIBLE,
                        10, 8, 360, 20, w, nullptr, nullptr, nullptr);
        auto edit = CreateWindowExW(
            WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
            10, 32, 200, 24, w, reinterpret_cast<HMENU>(101), nullptr, nullptr);
        SendMessageW(edit, EM_SETLIMITTEXT, 6, 0);
        CreateWindowExW(0, L"BUTTON", L"Approve once",
                        WS_CHILD | WS_VISIBLE | WS_TABSTOP, 10, 65, 120, 24, w,
                        reinterpret_cast<HMENU>(IDOK), nullptr, nullptr);
        CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE, 140, 65,
                        100, 24, w, reinterpret_cast<HMENU>(IDCANCEL), nullptr,
                        nullptr);
        SetTimer(w, 1, 120000, nullptr);
        return TRUE;
      }
      auto d = reinterpret_cast<DialogData *>(GetWindowLongPtrW(w, DWLP_USER));
      if (!d)
        return FALSE;
      if (message == WM_TIMER || message == WM_CLOSE ||
          (message == WM_COMMAND && LOWORD(wp) == IDCANCEL)) {
        d->response->timed_out = message == WM_TIMER;
        d->response->cancelled = true;
        EndDialog(w, IDCANCEL);
        return TRUE;
      }
      if (message == WM_COMMAND && LOWORD(wp) == IDOK) {
        wchar_t input[8]{};
        GetDlgItemTextW(w, 101, input, 8);
        std::string suffix;
        for (wchar_t c : input) {
          if (!c)
            break;
          if (c > 127) {
            d->response->cancelled = true;
            EndDialog(w, IDCANCEL);
            return TRUE;
          }
          suffix.push_back(char(c));
        }
        if (suffix != d->prompt->suffix) {
          d->response->cancelled = true;
          EndDialog(w, IDCANCEL);
          return TRUE;
        }
        d->response->suffix = suffix;
        d->response->displayed_hash = d->prompt->target_hash;
        d->response->checked = d->response->completed = true;
        EndDialog(w, IDOK);
        return TRUE;
      }
      return FALSE;
    };
    return DialogBoxIndirectParamW(GetModuleHandleW(nullptr), dialog, nullptr,
                                   procedure,
                                   reinterpret_cast<LPARAM>(&data)) == IDOK;
  } catch (...) {
    return false;
  }
}
} // namespace shiroha_l1_crypto
