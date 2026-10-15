#ifndef SHIROHA_EXCHANGE_OPEN_POLICY_H_
#define SHIROHA_EXCHANGE_OPEN_POLICY_H_
#include <windows.h>
#include <cstdint>
namespace shiroha_native {
// Shared by the production open and Synthetic ObjectOperations share checks.
constexpr ACCESS_MASK exchange_access(uint32_t mode) noexcept {
  return READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE |
      (mode != 3 ? FILE_READ_DATA : 0) | (mode == 0 ? FILE_WRITE_DATA : 0) |
      (mode == 3 || mode == 4 ? DELETE : 0);
}
constexpr ULONG exchange_share(uint32_t mode) noexcept {
  return mode == 2 ? FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE : FILE_SHARE_READ;
}
}
#endif
