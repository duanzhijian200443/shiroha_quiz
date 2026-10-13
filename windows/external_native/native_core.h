#ifndef SHIROHA_EXTERNAL_NATIVE_CORE_H_
#define SHIROHA_EXTERNAL_NATIVE_CORE_H_

#include <windows.h>
#include <dpapi.h>
#include "shiroha_external_native.h"

namespace shiroha_native {
// Internal, non-exported seam. Offline tests link only the core with fake
// operations, never the production wrappers or the production DLL.
struct Operations {
  BOOL (*protect)(DATA_BLOB*, DATA_BLOB*) noexcept;
  BOOL (*unprotect)(DATA_BLOB*, DATA_BLOB*) noexcept;
  void (*free_local)(void*) noexcept;
  HRESULT (*known_folder)(PWSTR*) noexcept;
  void (*free_task)(void*) noexcept;
};
const Operations& windows_operations() noexcept;

int32_t transform(uint32_t version, const uint8_t* input, uint64_t length,
                  uint8_t* output, uint64_t capacity, uint64_t* written,
                  bool decrypt, const Operations& ops) noexcept;
int32_t local_app_data(uint32_t version, uint8_t* output, uint64_t capacity,
                       uint64_t* written, const Operations& ops) noexcept;
}  // namespace shiroha_native
#endif
