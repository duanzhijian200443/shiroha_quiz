#ifndef SHIROHA_ASSOCIATION_RENAME_H_
#define SHIROHA_ASSOCIATION_RENAME_H_
#include <windows.h>
#include <winternl.h>
#include <cstddef>
#include <cstring>
#include "shiroha_external_native.h"

namespace shiroha_native {
// Documented user-mode NtSetInformationFile signature; no WDK/kernel linkage.
using SetInformationFile = NTSTATUS(NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG,
                                          FILE_INFORMATION_CLASS);
// FILE_RENAME_INFORMATION's non-extended layout with storage for the ONE fixed
// component. The SDK's user-mode winternl.h does not declare this WDK structure.
struct AssociationRenameBase {
  BOOLEAN ReplaceIfExists;
  HANDLE RootDirectory;
  ULONG FileNameLength;
  WCHAR FileName[1];
};
struct AssociationRenameInformation {
  BOOLEAN ReplaceIfExists;
  HANDLE RootDirectory;
  ULONG FileNameLength;
  WCHAR FileName[17];
};
static_assert(sizeof(void*) == 8 && sizeof(WCHAR) == 2);
static_assert(sizeof(AssociationRenameBase) == 24);
static_assert(offsetof(AssociationRenameBase, RootDirectory) == 8);
static_assert(offsetof(AssociationRenameBase, FileNameLength) == 16);
static_assert(offsetof(AssociationRenameBase, FileName) == 20);
static_assert(alignof(AssociationRenameInformation) == 8);
static_assert(offsetof(AssociationRenameInformation, RootDirectory) == 8);
static_assert(offsetof(AssociationRenameInformation, FileNameLength) == 16);
static_assert(offsetof(AssociationRenameInformation, FileName) == 20);
static_assert(sizeof(AssociationRenameInformation) == 56);

// Injectable call only: offline tests pass a fake NTAPI function. Callers must
// hold the validated state pin and synchronous, DELETE-bearing temp handle.
inline int32_t rename_association(SetInformationFile set_information, HANDLE temporary,
                                  HANDLE directory, bool existing) {
  if (!set_information || !temporary || temporary == INVALID_HANDLE_VALUE ||
      !directory || directory == INVALID_HANDLE_VALUE) return SHIROHA_NATIVE_COMMIT_UNKNOWN;
  constexpr WCHAR name[] = L"associations.bin";
  AssociationRenameInformation info{};
  info.ReplaceIfExists = existing ? TRUE : FALSE;
  info.RootDirectory = directory;
  info.FileNameLength = sizeof(name) - sizeof(WCHAR);
  std::memcpy(info.FileName, name, sizeof(name));
  constexpr ULONG name_bytes = sizeof(name) - sizeof(WCHAR);
  constexpr ULONG minimum_length = sizeof(AssociationRenameBase) + name_bytes;
  constexpr ULONG length = sizeof(info);
  static_assert(name_bytes == 32 && minimum_length == 56);
  static_assert(sizeof(info.FileName) >= sizeof(name));
  static_assert(offsetof(AssociationRenameInformation, FileName) + sizeof(name) <= sizeof(info));
  static_assert(length >= minimum_length && length == 56 && length <= sizeof(info));
  IO_STATUS_BLOCK io{};
  // An untouched output must not be mistaken for a successful completion.
  io.Status = static_cast<NTSTATUS>(0xC0000001u);
  const auto status = set_information(temporary, &io, &info, length,
      static_cast<FILE_INFORMATION_CLASS>(10)); // FileRenameInformation, not Ex.
  // These handles were opened FILE_SYNCHRONOUS_IO_NONALERT. Pending, warning,
  // failure and mismatched/untouched completion are never settled success.
  return status == 0 && io.Status == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN;
}
}  // namespace shiroha_native
#endif
