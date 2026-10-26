#include "../association_rename.h"
#include "../credential_rename.h"
#include "../discovery_rename.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <type_traits>

using CredentialBeginSignature = int32_t(__cdecl*)(uint32_t, uint64_t, uint32_t, uint8_t*, uint64_t, uint64_t*, uint64_t*);
using CredentialCommitSignature = int32_t(__cdecl*)(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t);
using CredentialAbortSignature = int32_t(__cdecl*)(uint32_t, uint64_t, uint64_t);
static_assert(std::is_same_v<decltype(&shiroha_native_credential_begin), CredentialBeginSignature>);
static_assert(std::is_same_v<decltype(&shiroha_native_credential_commit), CredentialCommitSignature>);
static_assert(std::is_same_v<decltype(&shiroha_native_credential_abort), CredentialAbortSignature>);

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
uint32_t expected_kind = 0;
NTSTATUS completion(PIO_STATUS_BLOCK io) {
  const NTSTATUS denied = static_cast<NTSTATUS>(0xC0000022u);
  if (scenario != 5) {
    io->Status = scenario == 2 || scenario == 8 ? denied :
        scenario == 4 || scenario == 9 ? 0x103 : scenario == 7 ? 1 : 0;
  }
  return scenario == 1 || scenario == 8 ? denied :
      scenario == 3 || scenario == 9 ? 0x103 : scenario == 6 ? 1 : 0;
}
NTSTATUS NTAPI fake_credential_set(HANDLE file, PIO_STATUS_BLOCK io, PVOID buffer, ULONG length,
                                  FILE_INFORMATION_CLASS information_class) {
  ++calls;
  require(file == reinterpret_cast<HANDLE>(uintptr_t{41}));
  require(static_cast<int>(information_class) == 10);
  require(length == 48 && length >= 24u + 20u);
  require(reinterpret_cast<uintptr_t>(buffer) % 8 == 0);
  require(reinterpret_cast<uintptr_t>(io) % alignof(IO_STATUS_BLOCK) == 0);
  const auto& info = *static_cast<CredentialRenameInformation*>(buffer);
  require(info.RootDirectory == reinterpret_cast<HANDLE>(uintptr_t{42}));
  require((info.ReplaceIfExists != FALSE) == expected_existing);
  require(info.FileNameLength == 20 && info.FileName[10] == 0);
  const auto* name = expected_kind == 1 ? L"issuer.bin" : expected_kind == 2 ? L"server.bin" : L"client.bin";
  require(std::memcmp(info.FileName, name, 22) == 0);
  return completion(io);
}
NTSTATUS NTAPI fake_discovery_set(HANDLE file, PIO_STATUS_BLOCK io, PVOID buffer, ULONG length,
                                 FILE_INFORMATION_CLASS information_class) {
  ++calls;
  require(file == reinterpret_cast<HANDLE>(uintptr_t{41}));
  require(static_cast<int>(information_class) == 10);
  require(reinterpret_cast<uintptr_t>(buffer) % 8 == 0);
  require(reinterpret_cast<uintptr_t>(io) % alignof(IO_STATUS_BLOCK) == 0);
  const auto& info = *static_cast<AssociationRenameBase*>(buffer);
  const auto* name = expected_kind == 1 ? L"endpoint.bin" :
      expected_kind == 2 ? L"anchor.der" : L"installation.id";
  const auto name_bytes = expected_kind == 1 ? 24u : expected_kind == 2 ? 20u : 30u;
  require(info.RootDirectory == reinterpret_cast<HANDLE>(uintptr_t{42}));
  require((info.ReplaceIfExists != FALSE) == expected_existing);
  require(info.FileNameLength == name_bytes);
  require(length == 56 && length >= 24u + name_bytes);
  require(std::memcmp(info.FileName, name, name_bytes + 2) == 0);
  return completion(io);
}
}
int main() {
  require(sizeof(AssociationRenameBase) == 24 && sizeof(AssociationRenameInformation) == 56);
  require(offsetof(AssociationRenameInformation, RootDirectory) == 8 &&
      offsetof(AssociationRenameInformation, FileNameLength) == 16 &&
      offsetof(AssociationRenameInformation, FileName) == 20);
  const auto file = reinterpret_cast<HANDLE>(uintptr_t{41});
  const auto parent = reinterpret_cast<HANDLE>(uintptr_t{42});
  for (const uint32_t kind : {1u, 2u, 4u}) {
    expected_kind = kind;
    for (const bool existing : {false, true}) {
      expected_existing = existing;
      for (scenario = 0; scenario < 10; ++scenario) {
        const auto count_before = calls;
        require(rename_credential(fake_credential_set, file, parent, kind, existing) ==
            (scenario == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN));
        require(calls == count_before + 1);
      }
    }
  }
  const auto credential_calls = calls;
  require(rename_credential(fake_credential_set, file, parent, 3, false) == SHIROHA_NATIVE_INVALID_INPUT);
  require(rename_credential(nullptr, file, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_credential(fake_credential_set, nullptr, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_credential(fake_credential_set, file, nullptr, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_credential(fake_credential_set, INVALID_HANDLE_VALUE, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_credential(fake_credential_set, file, INVALID_HANDLE_VALUE, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(calls == credential_calls);
  for (const uint32_t kind : {1u, 2u, 3u}) {
    expected_kind = kind;
    for (const bool existing : {false, true}) {
      expected_existing = existing;
      for (scenario = 0; scenario < 10; ++scenario) {
        const auto count_before = calls;
        const bool invalid = existing && kind != 1;
        require(rename_discovery(fake_discovery_set, file, parent, kind, existing) ==
            (invalid ? SHIROHA_NATIVE_INVALID_INPUT :
             scenario == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN));
        require(calls == count_before + (invalid ? 0 : 1));
      }
    }
  }
  const auto discovery_calls = calls;
  require(rename_discovery(fake_discovery_set, file, parent, 0, false) == SHIROHA_NATIVE_INVALID_INPUT);
  require(rename_discovery(fake_discovery_set, file, parent, 4, false) == SHIROHA_NATIVE_INVALID_INPUT);
  require(rename_discovery(nullptr, file, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_discovery(fake_discovery_set, nullptr, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_discovery(fake_discovery_set, file, nullptr, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_discovery(fake_discovery_set, INVALID_HANDLE_VALUE, parent, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(rename_discovery(fake_discovery_set, file, INVALID_HANDLE_VALUE, 1, false) == SHIROHA_NATIVE_COMMIT_UNKNOWN);
  require(calls == discovery_calls);
  scenario = 0; expected_existing = false;
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
