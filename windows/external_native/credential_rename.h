#ifndef SHIROHA_CREDENTIAL_RENAME_H_
#define SHIROHA_CREDENTIAL_RENAME_H_
#include <windows.h>
#include <cstddef>
#include <cstring>
#include "shiroha_external_native.h"
#include "association_rename.h"

namespace shiroha_native {
inline const wchar_t* credential_name(uint32_t kind) noexcept {
  switch (kind) {
    case 1: return L"issuer.bin";
    case 2: return L"server.bin";
    case 4: return L"client.bin";
    default: return nullptr;
  }
}
// All three fixed components have ten WCHARs, excluding their terminator.
struct CredentialRenameInformation {
  BOOLEAN ReplaceIfExists;
  HANDLE RootDirectory;
  DWORD FileNameLength;
  WCHAR FileName[11];
};
static_assert(sizeof(void*) == 8 && sizeof(WCHAR) == 2);
static_assert(alignof(CredentialRenameInformation) == 8);
static_assert(offsetof(CredentialRenameInformation, RootDirectory) == 8);
static_assert(offsetof(CredentialRenameInformation, FileNameLength) == 16);
static_assert(offsetof(CredentialRenameInformation, FileName) == 20);
static_assert(sizeof(CredentialRenameInformation) == 48);
// The same approved user-mode class-10 publication as P20. The caller retains
// its validated parent and synchronous DELETE-bearing temporary handle.
// Tests inject a function pointer, never the real file API.
inline int32_t rename_credential(SetInformationFile set_information, HANDLE temporary,
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
  constexpr ULONG length = sizeof(info);
  static_assert(length >= sizeof(AssociationRenameBase) + 20);
  static_assert(offsetof(CredentialRenameInformation, FileName) + 22 <= length);
  IO_STATUS_BLOCK io{};
  io.Status = static_cast<NTSTATUS>(0xC0000001u);
  const auto status = set_information(temporary, &io, &info, length,
      static_cast<FILE_INFORMATION_CLASS>(10));
  return status == 0 && io.Status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN;
}
}  // namespace shiroha_native
#endif
