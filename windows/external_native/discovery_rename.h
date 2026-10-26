#ifndef SHIROHA_DISCOVERY_RENAME_H_
#define SHIROHA_DISCOVERY_RENAME_H_
#include "credential_rename.h"
#include <cwchar>
namespace shiroha_native {
inline const wchar_t* discovery_name(uint32_t kind) noexcept {
  return kind == 1 ? L"endpoint.bin" : kind == 2 ? L"anchor.der" : kind == 3 ? L"installation.id" : nullptr;
}
inline int32_t rename_discovery(SetInformationFile call, HANDLE temp, HANDLE parent, uint32_t kind, bool replace) {
  const auto* name = discovery_name(kind);
  if (!name || (kind != 1 && replace)) return SHIROHA_NATIVE_INVALID_INPUT;
  if (!call || !temp || temp == INVALID_HANDLE_VALUE ||
      !parent || parent == INVALID_HANDLE_VALUE) return SHIROHA_NATIVE_COMMIT_UNKNOWN;
  struct Rename { BOOLEAN replace; HANDLE parent; DWORD length; WCHAR name[16]; } info{};
  static_assert(alignof(Rename) == 8 && sizeof(Rename) == 56);
  static_assert(offsetof(Rename, parent) == 8 && offsetof(Rename, length) == 16 &&
      offsetof(Rename, name) == 20);
  static_assert(sizeof(Rename) >= sizeof(AssociationRenameBase) + 30);
  info.replace = replace ? TRUE : FALSE; info.parent = parent;
  info.length = static_cast<DWORD>(std::wcslen(name) * sizeof(WCHAR));
  std::memcpy(info.name, name, info.length);
  IO_STATUS_BLOCK io{};
  io.Status = static_cast<NTSTATUS>(0xC0000001u);
  const auto status = call(temp, &io, &info, sizeof(info),
      static_cast<FILE_INFORMATION_CLASS>(10));
  return status == 0 && io.Status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN;
}
}
#endif
