#include "native_core.h"
#include <shlobj.h>

namespace {
BOOL protect(DATA_BLOB* input, DATA_BLOB* output) noexcept {
  // Frozen P16 9.B: user scope, flags 0, null description/entropy/reserved/prompt.
  return CryptProtectData(input, nullptr, nullptr, nullptr, nullptr, 0, output);
}
BOOL unprotect(DATA_BLOB* input, DATA_BLOB* output) noexcept {
  // No allocated description, optional entropy, prompt, machine scope or fallback.
  return CryptUnprotectData(input, nullptr, nullptr, nullptr, nullptr, 0, output);
}
void free_local(void* data) noexcept { LocalFree(data); }
HRESULT known_folder(PWSTR* path) noexcept {
  return SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, path);
}
void free_task(void* data) noexcept { CoTaskMemFree(data); }
const shiroha_native::Operations operations{
    protect, unprotect, free_local, known_folder, free_task};
}  // namespace

namespace shiroha_native {
const Operations& windows_operations() noexcept { return operations; }
}  // namespace shiroha_native

int32_t SHIROHA_NATIVE_CALL shiroha_native_local_app_data(
    uint32_t version, uint8_t* output, uint64_t capacity, uint64_t* written) {
  return shiroha_native::local_app_data(version, output, capacity, written, operations);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_dpapi_protect(
    uint32_t version, const uint8_t* input, uint64_t length,
    uint8_t* output, uint64_t capacity, uint64_t* written) {
  return shiroha_native::transform(version, input, length, output, capacity,
                                   written, false, operations);
}
int32_t SHIROHA_NATIVE_CALL shiroha_native_dpapi_unprotect(
    uint32_t version, const uint8_t* input, uint64_t length,
    uint8_t* output, uint64_t capacity, uint64_t* written) {
  return shiroha_native::transform(version, input, length, output, capacity,
                                   written, true, operations);
}
