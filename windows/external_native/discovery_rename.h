#ifndef SHIROHA_DISCOVERY_RENAME_H_
#define SHIROHA_DISCOVERY_RENAME_H_
#include "credential_rename.h"
#include <cwchar>
namespace shiroha_native {
inline const wchar_t* discovery_name(uint32_t kind) noexcept {
  return kind == 1 ? L"endpoint.bin" : kind == 2 ? L"anchor.der" : kind == 3 ? L"installation.id" : nullptr;
}
inline int32_t rename_discovery(SetCredentialInformation call, HANDLE temp, HANDLE parent, uint32_t kind, bool replace) {
  const auto* name = discovery_name(kind);
  if (!name || (kind != 1 && replace)) return SHIROHA_NATIVE_INVALID_INPUT;
  struct Rename { BOOLEAN replace; HANDLE parent; DWORD length; WCHAR name[16]; } info{};
  static_assert(offsetof(Rename, name) == offsetof(FILE_RENAME_INFO, FileName));
  info.replace = replace ? TRUE : FALSE; info.parent = parent;
  info.length = static_cast<DWORD>(std::wcslen(name) * sizeof(WCHAR));
  std::memcpy(info.name, name, info.length);
  return call && call(temp, FileRenameInfo, &info, sizeof(info)) ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN;
}
}
#endif
