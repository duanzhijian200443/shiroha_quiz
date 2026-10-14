#include "../association_rename.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

using namespace shiroha_native;
namespace {
int scenario = 0, calls = 0;
bool expected_existing = false;
void require(bool value) { if (!value) std::abort(); }
NTSTATUS NTAPI fake_set(HANDLE file, PIO_STATUS_BLOCK io, PVOID buffer, ULONG length,
                       FILE_INFORMATION_CLASS information_class) {
  ++calls;
  require(file == reinterpret_cast<HANDLE>(uintptr_t{41}));
  require(static_cast<int>(information_class) == 10);
  require(reinterpret_cast<uintptr_t>(buffer) % 8 == 0);
  require(reinterpret_cast<uintptr_t>(io) % alignof(IO_STATUS_BLOCK) == 0);
  const auto& info = *static_cast<AssociationRenameInformation*>(buffer);
  require(info.RootDirectory == reinterpret_cast<HANDLE>(uintptr_t{42}));
  require((info.ReplaceIfExists != FALSE) == expected_existing);
  require(info.FileNameLength == 32);
  // Independent documented minimum: x64 base size 24 plus 32 name bytes.
  if (length < 24u + info.FileNameLength || length > sizeof(AssociationRenameInformation)) {
    io->Status = static_cast<NTSTATUS>(0xC0000004u); // STATUS_INFO_LENGTH_MISMATCH
    return io->Status;
  }
  require(length == 56 && sizeof(AssociationRenameInformation) == 56);
  require(std::memcmp(info.FileName, L"associations.bin", 32) == 0);
  // Compare against independent expected NT ABI field offsets, including padding.
  require(reinterpret_cast<const uint8_t*>(&info.RootDirectory) - static_cast<const uint8_t*>(buffer) == 8);
  if (scenario != 5) io->Status = scenario == 2 ? static_cast<NTSTATUS>(0xC0000022u) : scenario == 4 ? 0x103 : 0;
  return scenario == 1 ? static_cast<NTSTATUS>(0xC0000022u) : scenario == 3 ? 0x103 : scenario == 6 ? 1 : 0;
}
}
int main() {
  require(sizeof(AssociationRenameBase) == 24 && sizeof(AssociationRenameInformation) == 56);
  require(offsetof(AssociationRenameInformation, RootDirectory) == 8 &&
      offsetof(AssociationRenameInformation, FileNameLength) == 16 &&
      offsetof(AssociationRenameInformation, FileName) == 20);
  const auto file = reinterpret_cast<HANDLE>(uintptr_t{41});
  const auto parent = reinterpret_cast<HANDLE>(uintptr_t{42});
  AssociationRenameInformation info{};
  info.RootDirectory = parent; info.FileNameLength = 32;
  std::memcpy(info.FileName, L"associations.bin", 34);
  IO_STATUS_BLOCK io{};
  require(fake_set(file, &io, &info, 52, static_cast<FILE_INFORMATION_CLASS>(10)) ==
      static_cast<NTSTATUS>(0xC0000004u));
  require(io.Status != 0);
  require(fake_set(file, &io, &info, 56, static_cast<FILE_INFORMATION_CLASS>(10)) == 0 && io.Status == 0);
  require(fake_set(file, &io, &info, 57, static_cast<FILE_INFORMATION_CLASS>(10)) != 0);
  for (const bool existing : {false, true}) {
    expected_existing = existing;
    for (scenario = 0; scenario < 7; ++scenario) {
      const auto before = calls;
      require(rename_association(fake_set, file, parent, existing) ==
          (scenario == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN));
      require(calls == before + 1); // No retry on pending, failure or mismatch.
    }
  }
  const auto before = calls;
  require(rename_association(nullptr, file, parent, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_association(fake_set, nullptr, parent, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_association(fake_set, file, INVALID_HANDLE_VALUE, true) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(calls == before);
  std::cout << "PASS: production NT rename seam, exact x64 layout/class/name/parent, settled dual-status success only\n";
}
