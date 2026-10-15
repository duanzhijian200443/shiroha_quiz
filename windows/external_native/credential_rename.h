#ifndef SHIROHA_CREDENTIAL_RENAME_H_
#define SHIROHA_CREDENTIAL_RENAME_H_
#include <windows.h>
#include <cstddef>
#include <cstring>
#include "shiroha_external_native.h"

namespace shiroha_native {
inline const wchar_t* credential_name(uint32_t kind) noexcept {
  switch (kind) {
    case 1: return L"issuer.bin";
    case 2: return L"server.bin";
    case 4: return L"client.bin";
    default: return nullptr;
  }
}
using SetCredentialInformation = BOOL(WINAPI*)(HANDLE, FILE_INFO_BY_HANDLE_CLASS, LPVOID, DWORD);
// All three fixed components have ten WCHARs, excluding their terminator.
struct CredentialRenameInformation {
  BOOLEAN ReplaceIfExists;
  HANDLE RootDirectory;
  DWORD FileNameLength;
  WCHAR FileName[11];
};
static_assert(sizeof(void*) == 8 && sizeof(WCHAR) == 2);
static_assert(offsetof(FILE_RENAME_INFO, RootDirectory) == 8);
static_assert(offsetof(FILE_RENAME_INFO, FileNameLength) == 16);
static_assert(offsetof(FILE_RENAME_INFO, FileName) == 20);
static_assert(sizeof(FILE_RENAME_INFO) == 24);
static_assert(offsetof(CredentialRenameInformation, FileName) == offsetof(FILE_RENAME_INFO, FileName));
static_assert(sizeof(CredentialRenameInformation) == 48);
// Documented Win32 FileRenameInfo relative-name form; no NT class-10 fallback.
// Tests inject a function pointer, never the real file API.
inline int32_t rename_credential(SetCredentialInformation set_information, HANDLE temporary,
                                 HANDLE directory, uint32_t kind, bool existing) {
  const auto* name = credential_name(kind);
  if (!name) return SHIROHA_NATIVE_INVALID_INPUT;
  if (!set_information || !temporary || temporary == INVALID_HANDLE_VALUE ||
      !directory || directory == INVALID_HANDLE_VALUE) return SHIROHA_NATIVE_COMMIT_UNKNOWN;
  CredentialRenameInformation info{};
  info.ReplaceIfExists = existing ? TRUE : FALSE;
  info.RootDirectory = directory;
  info.FileNameLength = 20;
  std::memcpy(info.FileName, name, sizeof(info.FileName));
  constexpr DWORD length = sizeof(info);
  static_assert(length >= sizeof(FILE_RENAME_INFO) + 20);
  static_assert(offsetof(CredentialRenameInformation, FileName) + 22 <= length);
  return set_information(temporary, FileRenameInfo, &info, length)
      ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN;
}
}  // namespace shiroha_native
#endif
