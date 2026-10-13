#include "protected_objects.h"
#include "native_core.h"
#include <aclapi.h>
#include <winternl.h>
#include <cstring>

namespace {
using namespace shiroha_native;
constexpr NTSTATUS name_collision = static_cast<NTSTATUS>(0xC0000035u);

struct WinHandle {
  HANDLE value = nullptr;
  ~WinHandle() noexcept { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
struct LocalAllocation {
  PSECURITY_DESCRIPTOR value = nullptr;
  ~LocalAllocation() noexcept { if (value) LocalFree(value); }
};

// Resolve only the documented user-mode export in the already loaded system
// ntdll. No private syscall numbers, fallback path, driver or Hook.
auto create_function() noexcept -> decltype(&NtCreateFile) {
  const auto module = GetModuleHandleW(L"ntdll.dll");
  const auto symbol = module ? GetProcAddress(module, "NtCreateFile") : nullptr;
  decltype(&NtCreateFile) result = nullptr;
  static_assert(sizeof(result) == sizeof(symbol), "Windows function pointer size");
  std::memcpy(&result, &symbol, sizeof(result));
  return result;
}

struct SecurityRecipe {
  SECURITY_DESCRIPTOR descriptor{};
  std::vector<uint8_t> acl;
  bool build(const Sid& sid, bool directory) {
    if (sid.empty() || !IsValidSid(const_cast<uint8_t*>(sid.data())) ||
        GetLengthSid(const_cast<uint8_t*>(sid.data())) != sid.size()) return false;
    const auto size = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + sid.size();
    acl.resize(size);
    auto* dacl = reinterpret_cast<PACL>(acl.data());
    return InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) &&
        SetSecurityDescriptorOwner(&descriptor, const_cast<uint8_t*>(sid.data()), FALSE) &&
        InitializeAcl(dacl, static_cast<DWORD>(size), ACL_REVISION) &&
        AddAccessAllowedAceEx(dacl, ACL_REVISION,
            directory ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE : 0,
            FILE_ALL_ACCESS, const_cast<uint8_t*>(sid.data())) &&
        SetSecurityDescriptorDacl(&descriptor, TRUE, dacl, FALSE) &&
        SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
  }
};

NTSTATUS open_native(HANDLE parent, const std::wstring& name, bool directory_create,
                     bool exclusive, ULONG disposition, PSECURITY_DESCRIPTOR security,
                     HANDLE& result) {
  result = nullptr;
  const auto create = create_function();
  if (!create || name.empty() || name.size() > 32766) return static_cast<NTSTATUS>(0xC000000Du);
  UNICODE_STRING unicode{};
  unicode.Buffer = const_cast<PWSTR>(name.data());
  unicode.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
  unicode.MaximumLength = unicode.Length;
  OBJECT_ATTRIBUTES attributes{};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = parent;
  attributes.ObjectName = &unicode;
  attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
  attributes.SecurityDescriptor = security;
  // Never combine DIRECTORY_FILE and OPEN_REPARSE_POINT: the official
  // NtCreateFile compatible-directory-options list does not include the latter.
  // New directory: FILE_CREATE, DIRECTORY_FILE, OBJ_DONT_REPARSE.
  // Existing directory: FILE_OPEN, OPEN_REPARSE_POINT, inspect its actual type.
  ULONG options = FILE_SYNCHRONOUS_IO_NONALERT |
      (directory_create ? FILE_DIRECTORY_FILE : FILE_OPEN_REPARSE_POINT);
  if (exclusive) options |= FILE_NON_DIRECTORY_FILE;
  const ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE |
      (exclusive ? FILE_READ_DATA | FILE_WRITE_DATA : FILE_LIST_DIRECTORY | FILE_TRAVERSE);
  IO_STATUS_BLOCK io{};
  WinHandle acquired;
  const auto status = create(&acquired.value, access, &attributes, &io, nullptr,
      FILE_ATTRIBUTE_NORMAL, exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE,
      disposition, options, nullptr, 0);
  // Synchronous operation: pending/unknown success and unexpected disposition
  // results are denied. RAII closes any anomalous returned handle on failure.
  if (status == 0 && acquired.value && acquired.value != INVALID_HANDLE_VALUE &&
      ((disposition == FILE_CREATE && io.Information == FILE_CREATED) ||
       (disposition == FILE_OPEN && io.Information == FILE_OPENED) ||
       (disposition == FILE_OPEN_IF && (io.Information == FILE_CREATED || io.Information == FILE_OPENED)))) {
    result = acquired.value;
    acquired.value = nullptr;
    return 0;
  }
  return status == 0 ? static_cast<NTSTATUS>(0xC000000Du) : status;
}

class WindowsObjects final : public ObjectOperations {
 public:
  int32_t user_sid(Sid& sid) override {
    WinHandle token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value)) return SHIROHA_NATIVE_UNAVAILABLE;
    DWORD size = 0;
    if (GetTokenInformation(token.value, TokenUser, nullptr, 0, &size) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER || size < sizeof(TOKEN_USER) || size > 65536)
      return SHIROHA_NATIVE_UNAVAILABLE;
    std::vector<uint8_t> data(size);
    if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size)) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto* user = reinterpret_cast<const TOKEN_USER*>(data.data());
    if (!IsValidSid(user->User.Sid)) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto length = GetLengthSid(user->User.Sid);
    const auto* bytes = static_cast<const uint8_t*>(user->User.Sid);
    sid.assign(bytes, bytes + length);
    return SHIROHA_NATIVE_OK;
  }

  int32_t local_directory(HANDLE& result) override;

  int32_t child(HANDLE parent, const wchar_t* component, bool directory,
                bool create, const Sid& sid, HANDLE& result) override {
    result = nullptr;
    if (!parent || parent == INVALID_HANDLE_VALUE || !component || !safe_component(component))
      return SHIROHA_NATIVE_INVALID_INPUT;
    if (!create) {
      // Bridge may open the App-owned ancestors, never initialize that root.
      return open_native(parent, component, false, false, FILE_OPEN, nullptr, result) == 0
          ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
    }
    SecurityRecipe security;
    if (!security.build(sid, directory)) return SHIROHA_NATIVE_UNAVAILABLE;
    if (!directory) {
      // OPEN_IF preserves existing bytes/security. Never truncate, overwrite or
      // mutate an existing object's ACL. Lock share mode is exactly zero.
      return open_native(parent, component, false, true, FILE_OPEN_IF,
                         &security.descriptor, result) == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
    }
    auto status = open_native(parent, component, true, false, FILE_CREATE,
                               &security.descriptor, result);
    if (status == name_collision) {
      // One existence branch, not a sharing/contention retry. Parent stays held.
      status = open_native(parent, component, false, false, FILE_OPEN, nullptr, result);
    }
    return status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }

  int32_t inspect(HANDLE handle, ObjectInfo& result) override {
    BY_HANDLE_FILE_INFORMATION file{};
    WCHAR filesystem[32]{};
    DWORD volume = 0;
    if (GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, &file) ||
        !GetVolumeInformationByHandleW(handle, nullptr, 0, &volume, nullptr, nullptr, filesystem, 32))
      return SHIROHA_NATIVE_UNAVAILABLE;
    // Drive classification derives from the actual handle's volume GUID, never
    // a drive-letter string supplied by a caller. UNC/non-GUID results deny.
    WCHAR path[32768]{};
    const auto length = GetFinalPathNameByHandleW(handle, path, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
    if (length == 0 || length >= 32768) return SHIROHA_NATIVE_UNAVAILABLE;
    std::wstring final_path(path, length);
    if (final_path.rfind(L"\\\\?\\Volume{", 0) != 0) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto end = final_path.find(L"}\\");
    if (end == std::wstring::npos) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto volume_path = final_path.substr(0, end + 2);
    result.drive_type = GetDriveTypeW(volume_path.c_str());
    result.filesystem = filesystem;
    result.volume = file.dwVolumeSerialNumber;
    if (volume != file.dwVolumeSerialNumber) return SHIROHA_NATIVE_UNAVAILABLE;
    result.file = (static_cast<uint64_t>(file.nFileIndexHigh) << 32) | file.nFileIndexLow;
    result.attributes = file.dwFileAttributes;
    result.links = file.nNumberOfLinks;
    LocalAllocation security;
    PSID owner = nullptr;
    PACL dacl = nullptr;
    if (GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                        &owner, nullptr, &dacl, nullptr, &security.value) != ERROR_SUCCESS ||
        !security.value || !IsValidSecurityDescriptor(security.value) || !owner || !IsValidSid(owner))
      return SHIROHA_NATIVE_UNAVAILABLE;
    auto* owner_bytes = static_cast<const uint8_t*>(owner);
    result.owner.assign(owner_bytes, owner_bytes + GetLengthSid(owner));
    BOOL present = FALSE, defaulted = FALSE;
    SECURITY_DESCRIPTOR_CONTROL control{};
    DWORD revision = 0;
    if (!GetSecurityDescriptorDacl(security.value, &present, &dacl, &defaulted) ||
        !GetSecurityDescriptorControl(security.value, &control, &revision)) return SHIROHA_NATIVE_UNAVAILABLE;
    result.dacl_present = present && dacl != nullptr;
    result.dacl_protected = (control & SE_DACL_PROTECTED) != 0;
    result.aces.clear();
    if (!result.dacl_present) return SHIROHA_NATIVE_OK; // Core rejects controlled objects.
    if (!IsValidAcl(dacl)) return SHIROHA_NATIVE_UNAVAILABLE;
    // The policy accepts exactly one ACE. Bound extraction before allocation.
    if (dacl->AceCount != 1) { result.dacl_present = false; return SHIROHA_NATIVE_OK; }
    void* raw = nullptr;
    if (!GetAce(dacl, 0, &raw) || !raw) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto* header = static_cast<const ACE_HEADER*>(raw);
    Ace ace;
    ace.type = header->AceType; ace.flags = header->AceFlags;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { result.dacl_present = false; return SHIROHA_NATIVE_OK; }
    const auto* allowed = static_cast<const ACCESS_ALLOWED_ACE*>(raw);
    if (header->AceSize < sizeof(ACCESS_ALLOWED_ACE)) return SHIROHA_NATIVE_UNAVAILABLE;
    auto* ace_sid = const_cast<DWORD*>(&allowed->SidStart);
    if (!IsValidSid(ace_sid) || GetLengthSid(ace_sid) > header->AceSize - offsetof(ACCESS_ALLOWED_ACE, SidStart))
      return SHIROHA_NATIVE_UNAVAILABLE;
    ace.mask = allowed->Mask;
    const auto* bytes = reinterpret_cast<const uint8_t*>(ace_sid);
    ace.sid.assign(bytes, bytes + GetLengthSid(ace_sid));
    result.aces.push_back(std::move(ace));
    return SHIROHA_NATIVE_OK;
  }
  bool close(HANDLE handle) noexcept override { return CloseHandle(handle) != FALSE; }
};

// Reuse P18's exact known-folder operation; do not accept environment/caller
// paths. Exposed here internally by native_windows.cpp, not through the C ABI.
int32_t WindowsObjects::local_directory(HANDLE& result) {
  result = nullptr;
  alignas(8) uint8_t output[SHIROHA_NATIVE_MAX_BYTES]{};
  uint64_t written = 0;
  const auto status = local_app_data(SHIROHA_NATIVE_ABI_VERSION, output,
                                    sizeof(output), &written, windows_operations());
  if (status != SHIROHA_NATIVE_OK) return status;
  if (!written || written % sizeof(wchar_t) != 0) return SHIROHA_NATIVE_UNAVAILABLE;
  std::wstring path(reinterpret_cast<const wchar_t*>(output), static_cast<size_t>(written / 2));
  std::wstring name;
  if (!local_nt_name(path, name)) return SHIROHA_NATIVE_UNAVAILABLE;
  return open_native(nullptr, name, false, false, FILE_OPEN, nullptr, result) == 0
      ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
}

WindowsObjects operations;
ProtectedObjects owners(operations); // Passive construction; no OS calls.
}  // namespace

int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_acquire(uint32_t version, uint32_t role, uint64_t* token) {
  return owners.acquire(version, role, token);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_validate(uint32_t version, uint64_t token) {
  return owners.validate(version, token);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_owner_close(uint32_t version, uint64_t token) {
  return owners.close(version, token);
}
