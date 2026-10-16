// Windows-only leaf candidates. COMPILE ONLY: never linked to a runnable
// target.
#include "diagnostics/l1_windows_operations.h"

#include <aclapi.h>
#include <psapi.h>
#include <sddl.h>

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
struct TokenOwner {
  HANDLE value = nullptr;
  ~TokenOwner() {
    if (value) CloseHandle(value);
  }
};
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
  if (!ConvertStringSidToSidW(sid.c_str(), &expected.value)) return false;
  TokenOwner token;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return false;
  std::vector<unsigned char> bytes;
  if (!token_field(token.value, TokenUser, bytes) ||
      !EqualSid(reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid,
                expected.value))
    return false;
  if (!token_field(token.value, TokenElevation, bytes) ||
      reinterpret_cast<TOKEN_ELEVATION *>(bytes.data())->TokenIsElevated)
    return false;
  if (!token_field(token.value, TokenType, bytes) ||
      *reinterpret_cast<TOKEN_TYPE *>(bytes.data()) != TokenPrimary)
    return false;
  if (!token_field(token.value, TokenIntegrityLevel, bytes)) return false;
  auto label =
      reinterpret_cast<TOKEN_MANDATORY_LABEL *>(bytes.data())->Label.Sid;
  if (!IsValidSid(label) || *GetSidSubAuthorityCount(label) == 0 ||
      *GetSidSubAuthority(label, *GetSidSubAuthorityCount(label) - 1) !=
          SECURITY_MANDATORY_MEDIUM_RID)
    return false;
  if (IsTokenRestricted(token.value)) return false;
  if (!token_field(token.value, TokenPrivileges, bytes)) return false;
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
}  // namespace shiroha_l1_crypto
