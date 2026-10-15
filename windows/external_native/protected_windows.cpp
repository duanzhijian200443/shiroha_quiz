#include "protected_objects.h"
#include "native_core.h"
#include "association_rename.h"
#include "credential_rename.h"
#include "discovery_rename.h"
#include "diagnostics/p20_test_root.h"
#include <aclapi.h>
#include <winternl.h>
#include <cstring>
#include <bcrypt.h>

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
  bool build(const Sid& sid, bool directory, DWORD access = FILE_ALL_ACCESS) {
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
            access, const_cast<uint8_t*>(sid.data())) &&
        SetSecurityDescriptorDacl(&descriptor, TRUE, dacl, FALSE) &&
        SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
  }
};

NTSTATUS open_native(HANDLE parent, const std::wstring& name, bool directory_create,
                     bool exclusive, ULONG disposition, PSECURITY_DESCRIPTOR security,
                     HANDLE& result, ACCESS_MASK file_access = 0, ULONG file_share = MAXDWORD) {
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
  const ACCESS_MASK access = file_access ? file_access : READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE |
      (exclusive ? FILE_READ_DATA | FILE_WRITE_DATA : FILE_LIST_DIRECTORY | FILE_TRAVERSE);
  IO_STATUS_BLOCK io{};
  WinHandle acquired;
  const auto status = create(&acquired.value, access, &attributes, &io, nullptr,
      FILE_ATTRIBUTE_NORMAL, file_share != MAXDWORD ? file_share : (exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE),
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
      // Existing-only acquisition must retain the file lock's no-sharing policy.
      // Directory/lock absence never enters a create or security-repair branch.
      return open_native(parent, component, false, !directory, FILE_OPEN, nullptr, result) == 0
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

  int32_t association_open(HANDLE parent, const Sid&, HANDLE& result) override {
    // Read handle denies write sharing. Delete sharing permits this holder's
    // atomic rename; the core compares the current name's identity before it.
    const auto status = open_native(parent, L"associations.bin", false, true, FILE_OPEN,
        nullptr, result, READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE);
    if (status == static_cast<NTSTATUS>(0xC0000034u)) return SHIROHA_NATIVE_MISSING;
    return status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t credential_open(HANDLE parent, uint32_t kind, const Sid&, HANDLE& result) override {
    result = nullptr;
    const auto* name = credential_name(kind);
    if (!name) return SHIROHA_NATIVE_INVALID_INPUT;
    const auto status = open_native(parent, name, false, true, FILE_OPEN,
        nullptr, result, READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE);
    if (status == static_cast<NTSTATUS>(0xC0000034u)) return SHIROHA_NATIVE_MISSING;
    return status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t credential_replace(HANDLE temporary, HANDLE directory, uint32_t kind, bool existing) override {
    return rename_credential(SetFileInformationByHandle, temporary, directory, kind, existing);
  }
  int32_t discovery_open(HANDLE parent, uint32_t kind, HANDLE& result) override {
    result = nullptr;
    const auto* name = discovery_name(kind);
    if (!name) return SHIROHA_NATIVE_INVALID_INPUT;
    const auto status = open_native(parent, name, false, true, FILE_OPEN, nullptr, result,
        READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE);
    if (status == static_cast<NTSTATUS>(0xC0000034u)) return SHIROHA_NATIVE_MISSING;
    return status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t discovery_replace(HANDLE temp, HANDLE parent, uint32_t kind, bool replace) override {
    return rename_discovery(SetFileInformationByHandle, temp, parent, kind, replace);
  }
  int32_t exchange_lock(const ObjectInfo& directory, const Sid& sid, HANDLE& result) override {
    result = nullptr;
    // Cross-session Exchange quota serialization. No extra directory entry.
    const auto name = L"Global\\Shiroha.Exchange." + std::to_wstring(directory.volume) + L"." + std::to_wstring(directory.file);
    SecurityRecipe recipe;
    if (!recipe.build(sid, false, MUTEX_ALL_ACCESS)) return SHIROHA_NATIVE_UNAVAILABLE;
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), &recipe.descriptor, FALSE};
    WinHandle mutex;
    mutex.value = CreateMutexExW(&attributes, name.c_str(), 0, MUTEX_ALL_ACCESS);
    if (!mutex.value) return SHIROHA_NATIVE_UNAVAILABLE;
    LocalAllocation security;
    PSID owner = nullptr;
    PACL dacl = nullptr;
    if (GetSecurityInfo(mutex.value, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner, nullptr, &dacl, nullptr, &security.value) != ERROR_SUCCESS || !security.value ||
        !IsValidSecurityDescriptor(security.value) || !owner || !IsValidSid(owner) ||
        !EqualSid(owner, const_cast<uint8_t*>(sid.data()))) return SHIROHA_NATIVE_UNAVAILABLE;
    BOOL present = FALSE, defaulted = FALSE;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    if (!GetSecurityDescriptorDacl(security.value, &present, &dacl, &defaulted) || !present || !dacl ||
        !IsValidAcl(dacl) || !GetSecurityDescriptorControl(security.value, &control, &revision) ||
        !(control & SE_DACL_PROTECTED) || dacl->AceCount != 1) return SHIROHA_NATIVE_UNAVAILABLE;
    void* ace = nullptr;
    if (!GetAce(dacl, 0, &ace) || !ace) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto* allowed = static_cast<const ACCESS_ALLOWED_ACE*>(ace);
    if (allowed->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || allowed->Header.AceFlags != 0 ||
        allowed->Header.AceSize != sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + sid.size() ||
        allowed->Mask != MUTEX_ALL_ACCESS || !IsValidSid(const_cast<DWORD*>(&allowed->SidStart)) ||
        GetLengthSid(const_cast<DWORD*>(&allowed->SidStart)) != sid.size() ||
        !EqualSid(const_cast<DWORD*>(&allowed->SidStart), const_cast<uint8_t*>(sid.data()))) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto wait = WaitForSingleObject(mutex.value, 0);
    if (wait == WAIT_ABANDONED) { ReleaseMutex(mutex.value); return SHIROHA_NATIVE_UNAVAILABLE; }
    if (wait != WAIT_OBJECT_0) return SHIROHA_NATIVE_UNAVAILABLE;
    result = mutex.value; mutex.value = nullptr;
    return SHIROHA_NATIVE_OK;
  }
  bool exchange_unlock(HANDLE mutex) noexcept override {
    const bool released = ReleaseMutex(mutex) != FALSE;
    const bool closed = CloseHandle(mutex) != FALSE;
    return released && closed;
  }
  int32_t exchange_count(HANDLE directory, size_t& count) override {
    count = 0;
    alignas(FILE_ID_BOTH_DIR_INFO) uint8_t buffer[65536]{};
    bool first = true;
    for (;;) {
      SecureZeroMemory(buffer, sizeof(buffer));
      if (!GetFileInformationByHandleEx(directory,
          first ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo, buffer, sizeof(buffer)))
        return GetLastError() == ERROR_NO_MORE_FILES ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
      first = false;
      size_t offset = 0;
      for (;;) {
        const auto base = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
        if (offset > sizeof(buffer) - base) return SHIROHA_NATIVE_UNAVAILABLE;
        const auto* info = reinterpret_cast<const FILE_ID_BOTH_DIR_INFO*>(buffer + offset);
        if (info->FileNameLength % 2 || info->FileNameLength > sizeof(buffer) - offset - base) return SHIROHA_NATIVE_UNAVAILABLE;
        const std::wstring name(info->FileName, info->FileNameLength / 2);
        // ALL objects count, including directories, unknown names and leftovers.
        if (name != L"." && name != L".." && ++count > 32) return SHIROHA_NATIVE_OK;
        if (!info->NextEntryOffset) break;
        if (info->NextEntryOffset < base || info->NextEntryOffset % alignof(FILE_ID_BOTH_DIR_INFO) ||
            info->NextEntryOffset > sizeof(buffer) - offset - base) return SHIROHA_NATIVE_UNAVAILABLE;
        offset += info->NextEntryOffset;
      }
    }
  }
  int32_t exchange_open(HANDLE directory, const std::wstring& name, uint32_t mode,
                        const Sid& sid, HANDLE& result) override {
    result = nullptr;
    if (!safe_component(name) || mode > 3) return SHIROHA_NATIVE_INVALID_INPUT;
    SecurityRecipe security;
    if (mode == 0 && !security.build(sid, false)) return SHIROHA_NATIVE_UNAVAILABLE;
    ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
    if (mode != 3) access |= FILE_READ_DATA;
    if (mode == 0) access |= FILE_WRITE_DATA;
    if (mode == 3) access |= DELETE;
    WinHandle acquired;
    const auto status = open_native(directory, name, false, true, mode == 0 ? FILE_CREATE : FILE_OPEN,
        mode == 0 ? &security.descriptor : nullptr, acquired.value, access,
        mode == 2 ? FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE : FILE_SHARE_READ);
    if (status == static_cast<NTSTATUS>(0xC0000034u)) return SHIROHA_NATIVE_MISSING;
    if (status != 0) return SHIROHA_NATIVE_UNAVAILABLE;
    // Reject an on-disk casing alias on normal case-insensitive NTFS as well.
    alignas(FILE_NAME_INFO) uint8_t bytes[65536]{};
    if (!GetFileInformationByHandleEx(acquired.value, FileNameInfo, bytes, sizeof(bytes))) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto* info = reinterpret_cast<const FILE_NAME_INFO*>(bytes);
    if (info->FileNameLength % 2 || info->FileNameLength > sizeof(bytes) - offsetof(FILE_NAME_INFO, FileName)) return SHIROHA_NATIVE_UNAVAILABLE;
    const std::wstring actual(info->FileName, info->FileNameLength / 2);
    if (actual.substr(actual.find_last_of(L'\\') + 1) != name) return SHIROHA_NATIVE_UNAVAILABLE;
    result = acquired.value; acquired.value = nullptr;
    return SHIROHA_NATIVE_OK;
  }
  int32_t exchange_read(HANDLE file, size_t maximum, std::vector<uint8_t>& output) override {
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)) return SHIROHA_NATIVE_UNAVAILABLE;
    if (size.QuadPart <= 0 || static_cast<uint64_t>(size.QuadPart) > maximum) return SHIROHA_NATIVE_DATA_CORRUPT;
    return read_file(file, output);
  }
  int32_t exchange_delete(HANDLE file) override {
    FILE_DISPOSITION_INFO disposition{TRUE};
    return SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof(disposition))
        ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t read_file(HANDLE file, std::vector<uint8_t>& output) override {
    LARGE_INTEGER size{}, after{};
    if (!GetFileSizeEx(file, &size)) return SHIROHA_NATIVE_UNAVAILABLE;
    if (size.QuadPart <= 0 || size.QuadPart > SHIROHA_NATIVE_MAX_BYTES) return SHIROHA_NATIVE_DATA_CORRUPT;
    output.resize(static_cast<size_t>(size.QuadPart));
    DWORD received = 0;
    if (!ReadFile(file, output.data(), static_cast<DWORD>(output.size()), &received, nullptr) ||
        received != output.size() || !GetFileSizeEx(file, &after) || after.QuadPart != size.QuadPart)
      return SHIROHA_NATIVE_UNAVAILABLE;
    return SHIROHA_NATIVE_OK;
  }
  int32_t temporary_count(HANDLE directory, size_t& count) override {
    count = 0;
    alignas(FILE_ID_BOTH_DIR_INFO) uint8_t buffer[65536]{};
    bool first = true;
    size_t entries = 0;
    for (;;) {
      SecureZeroMemory(buffer, sizeof(buffer));
      if (!GetFileInformationByHandleEx(directory,
          first ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo, buffer, sizeof(buffer)))
        return GetLastError() == ERROR_NO_MORE_FILES ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
      first = false;
      size_t offset = 0;
      for (;;) {
        if (++entries > 4096) return SHIROHA_NATIVE_RESOURCE_LIMIT;
        const auto base = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
        if (offset > sizeof(buffer) - base) return SHIROHA_NATIVE_UNAVAILABLE;
        const auto* info = reinterpret_cast<const FILE_ID_BOTH_DIR_INFO*>(buffer + offset);
        if (info->FileNameLength % 2 || info->FileNameLength > sizeof(buffer) - offset - base)
          return SHIROHA_NATIVE_UNAVAILABLE;
        const std::wstring name(info->FileName, info->FileNameLength / 2);
        if (name.rfind(L"~tmp-", 0) == 0 && ++count >= 32) return SHIROHA_NATIVE_OK;
        if (!info->NextEntryOffset) break;
        if (info->NextEntryOffset < base || info->NextEntryOffset % alignof(FILE_ID_BOTH_DIR_INFO) ||
            info->NextEntryOffset > sizeof(buffer) - offset - base) return SHIROHA_NATIVE_UNAVAILABLE;
        offset += info->NextEntryOffset;
      }
    }
  }
  int32_t random_name(std::wstring& runtime, std::wstring& random) override {
    uint8_t bytes[12]{};
    if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
      return SHIROHA_NATIVE_UNAVAILABLE;
    constexpr wchar_t digits[] = L"0123456789abcdef";
    runtime.clear(); random.clear();
    for (size_t i = 0; i < sizeof(bytes); ++i) {
      auto& text = i < 8 ? runtime : random;
      text += digits[bytes[i] >> 4]; text += digits[bytes[i] & 15];
    }
    return SHIROHA_NATIVE_OK;
  }
  int32_t temporary_create(HANDLE parent, const std::wstring& name, const Sid& sid, HANDLE& result) override {
    if (!safe_component(name)) return SHIROHA_NATIVE_INVALID_INPUT;
    SecurityRecipe security;
    if (!security.build(sid, false)) return SHIROHA_NATIVE_UNAVAILABLE;
    // FILE_CREATE is CREATE_NEW: collisions never open/truncate foreign files.
    return open_native(parent, name, false, true, FILE_CREATE, &security.descriptor, result,
        READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_WRITE_DATA | DELETE | SYNCHRONIZE, 0) == 0
        ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t write_file(HANDLE file, const uint8_t* input, uint64_t length) override {
    DWORD written = 0;
    return WriteFile(file, input, static_cast<DWORD>(length), &written, nullptr) && written == length
        ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t flush_file(HANDLE file) override {
    return FlushFileBuffers(file) ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
  }
  int32_t replace_file(HANDLE temporary, HANDLE directory, bool existing) override {
    const auto module = GetModuleHandleW(L"ntdll.dll");
    const auto symbol = module ? GetProcAddress(module, "NtSetInformationFile") : nullptr;
    SetInformationFile set_information = nullptr;
    static_assert(sizeof(set_information) == sizeof(symbol), "Windows function pointer size");
    std::memcpy(&set_information, &symbol, sizeof(symbol));
    return rename_association(set_information, temporary, directory, existing);
  }
};

// Reuse P18's exact known-folder operation; do not accept environment/caller
// paths. Exposed here internally by native_windows.cpp, not through the C ABI.
int32_t production_object_root(std::wstring& path) {
  alignas(8) uint8_t output[SHIROHA_NATIVE_MAX_BYTES]{};
  uint64_t written = 0;
  const auto status = local_app_data(SHIROHA_NATIVE_ABI_VERSION, output,
                                    sizeof(output), &written, windows_operations());
  if (status != SHIROHA_NATIVE_OK) return status;
  if (!written || written % sizeof(wchar_t) != 0) return SHIROHA_NATIVE_UNAVAILABLE;
  path.assign(reinterpret_cast<const wchar_t*>(output), static_cast<size_t>(written / 2));
  return SHIROHA_NATIVE_OK;
}

int32_t WindowsObjects::local_directory(HANDLE& result) {
  result = nullptr;
  std::wstring path;
  const auto status = resolve_object_root(path, production_object_root);
  if (status != SHIROHA_NATIVE_OK) return status;
  std::wstring name;
  if (!local_nt_name(path, name)) return SHIROHA_NATIVE_UNAVAILABLE;
  return open_native(nullptr, name, false, false, FILE_OPEN, nullptr, result) == 0
      ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
}

WindowsObjects operations;
#ifdef SHIROHA_BATCH3_EXISTING_ONLY
ProtectedObjects owners(operations, ProtectedObjects::OpenMode::existing_only);
#else
ProtectedObjects owners(operations); // Passive construction; no OS calls.
#endif
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
int32_t SHIROHA_NATIVE_CALL shiroha_native_association_begin(uint32_t version, uint64_t owner,
    uint8_t* output, uint64_t capacity, uint64_t* written, uint64_t* ticket) {
  return owners.association_begin(version, owner, output, capacity, written, ticket);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_association_commit(uint32_t version, uint64_t owner,
    uint64_t ticket, const uint8_t* input, uint64_t length) {
  return owners.association_commit(version, owner, ticket, input, length);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_association_abort(uint32_t version, uint64_t owner, uint64_t ticket) {
  return owners.association_abort(version, owner, ticket);
}

int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_begin(uint32_t version, uint64_t owner,
    uint32_t kind, uint8_t* output, uint64_t capacity, uint64_t* written, uint64_t* ticket) {
  return owners.credential_begin(version, owner, kind, output, capacity, written, ticket);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_commit(uint32_t version, uint64_t owner,
    uint64_t ticket, const uint8_t* input, uint64_t length) {
  return owners.credential_commit(version, owner, ticket, input, length);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_credential_abort(uint32_t version, uint64_t owner, uint64_t ticket) {
  return owners.credential_abort(version, owner, ticket);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_create(uint32_t version, uint64_t owner,
    uint32_t kind, const uint8_t* id, const uint8_t* input, uint64_t length, uint64_t* receipt) {
  return owners.exchange_create(version, owner, kind, id, input, length, receipt);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_read(uint32_t version, uint64_t owner,
    uint32_t kind, const uint8_t* id, uint8_t* output, uint64_t capacity, uint64_t* written) {
  return owners.exchange_read(version, owner, kind, id, output, capacity, written);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_exchange_cleanup(uint32_t version, uint64_t owner, uint64_t receipt) {
  return owners.exchange_cleanup(version, owner, receipt);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_discovery_publish(uint32_t version, uint64_t owner,
    uint32_t kind, const uint8_t* input, uint64_t length) {
  return owners.discovery_publish(version, owner, kind, input, length);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_discovery_read(uint32_t version, uint64_t owner,
    uint32_t kind, uint8_t* output, uint64_t capacity, uint64_t* written) {
  return owners.discovery_read(version, owner, kind, output, capacity, written);
}
