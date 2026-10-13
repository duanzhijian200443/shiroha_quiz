#include "native_core.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>

namespace {
int calls = 0;
int local_frees = 0;
int task_frees = 0;
bool fail = false;
bool malformed = false;
bool cleared = true;
DWORD result_size = 4;
constexpr uint8_t fixture[] = {9, 8, 7, 6};  // Public synthetic bytes only.

void check(bool ok) {
  if (!ok) {
    std::cerr << "FAIL: offline native contract\n";
    std::exit(1);
  }
}

BOOL transform(DATA_BLOB*, DATA_BLOB* output) noexcept {
  ++calls;
  if (malformed) return TRUE;  // Invalid successful OS result.
  output->cbData = result_size;
  output->pbData = static_cast<BYTE*>(std::malloc(result_size));
  if (!output->pbData) return FALSE;
  std::memset(output->pbData, 42, result_size);
  std::memcpy(output->pbData, fixture, sizeof(fixture));
  return fail ? FALSE : TRUE;
}
void free_local(void* data) noexcept {
  ++local_frees;
  for (size_t i = 0; i < result_size; ++i) {
    if (static_cast<uint8_t*>(data)[i] != 0) cleared = false;
  }
  std::free(data);
}
HRESULT known_folder(PWSTR* output) noexcept {
  ++calls;
  // Supplementary Unicode + spaces; fake allocation, no Windows directory read.
  const WCHAR path[] = L"C:\\synthetic user\\\xD83D\xDE00";
  *output = static_cast<PWSTR>(std::malloc(sizeof(path)));
  if (!*output) return E_OUTOFMEMORY;
  std::memcpy(*output, path, sizeof(path));
  return fail ? E_FAIL : S_OK;
}
void free_task(void* data) noexcept {
  ++task_frees;
  std::free(data);
}
const shiroha_native::Operations fake{
    transform, transform, free_local, known_folder, free_task};
}  // namespace

int main() {
  check(shiroha_native_abi_version() == 2);
  check(shiroha_native_buffer_alloc(0) == nullptr);
  check(shiroha_native_buffer_alloc(65537) == nullptr);
  check(shiroha_native_buffer_alloc((std::numeric_limits<uint64_t>::max)()) == nullptr);
  auto* allocation = shiroha_native_buffer_alloc(65536);
  check(allocation != nullptr && reinterpret_cast<uintptr_t>(allocation) % 8 == 0);
  for (size_t i = 0; i < 65536; ++i) check(allocation[i] == 0);
  std::memset(allocation, 42, 65536);
  shiroha_native_buffer_free(allocation);
  shiroha_native_buffer_free(nullptr);

  uint8_t input[] = {1, 2, 3};
  uint8_t output[128]{};
  uint64_t written = 99;
  auto run = [&](uint32_t version, const uint8_t* data, uint64_t size,
                 uint8_t* target, uint64_t capacity, uint64_t* count,
                 bool decrypt = false) {
    return shiroha_native::transform(version, data, size, target, capacity,
                                     count, decrypt, fake);
  };
  check(run(3, input, 3, output, 128, &written) == SHIROHA_NATIVE_ABI_MISMATCH);
  check(written == 0 && calls == 0);
  for (auto size : {uint64_t{0}, uint64_t{65537},
                    (std::numeric_limits<uint64_t>::max)()}) {
    written = 99;
    std::memset(output, 42, sizeof(output));
    check(run(1, input, size, output, 128, &written) == SHIROHA_NATIVE_INVALID_INPUT);
    check(written == 0 && calls == 0);
    for (auto byte : output) check(byte == 0);
  }
  check(run(1, nullptr, 3, output, 128, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, nullptr, 128, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, output, 0, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, output, 65537, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, output, 128, nullptr) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, input, 3, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(input[0] == 1 && calls == 0);
  check(run(1, input, 3, output, 128,
            reinterpret_cast<uint64_t*>(output + 1)) == SHIROHA_NATIVE_INVALID_INPUT);
  check(run(1, input, 3, output, 128,
            reinterpret_cast<uint64_t*>(output)) == SHIROHA_NATIVE_INVALID_INPUT);
  const auto near_end = reinterpret_cast<const uint8_t*>(
      (std::numeric_limits<uintptr_t>::max)() - 1);
  check(run(1, near_end, 3, output, 128, &written) == SHIROHA_NATIVE_INVALID_INPUT);
  check(calls == 0);

  for (bool decrypt : {false, true}) {
    check(run(1, input, 3, output, 128, &written, decrypt) == SHIROHA_NATIVE_OK);
    check(written == sizeof(fixture) && std::memcmp(output, fixture, sizeof(fixture)) == 0);
    check(output[4] == 0 && cleared);
    check(run(1, input, 3, output, 2, &written, decrypt) == SHIROHA_NATIVE_RESOURCE_LIMIT);
    check(written == 0 && output[0] == 0 && output[1] == 0 && cleared);
    fail = true;
    check(run(1, input, 3, output, 128, &written, decrypt) ==
          (decrypt ? SHIROHA_NATIVE_DATA_CORRUPT : SHIROHA_NATIVE_UNAVAILABLE));
    check(written == 0 && cleared);
    for (auto byte : output) check(byte == 0);
    fail = false;
  }
  check(local_frees == 6);
  malformed = true;
  check(run(1, input, 3, output, 128, &written) == SHIROHA_NATIVE_DATA_CORRUPT);
  check(written == 0);
  malformed = false;
  result_size = 65537;  // Legitimate expansion still fails closed at the cap.
  check(run(1, input, 3, output, 128, &written) == SHIROHA_NATIVE_RESOURCE_LIMIT);
  check(written == 0 && cleared && local_frees == 7);
  result_size = 4;

  check(shiroha_native::local_app_data(3, output, 128, &written, fake) == SHIROHA_NATIVE_ABI_MISMATCH);
  check(shiroha_native::local_app_data(1, output, 128, &written, fake) == SHIROHA_NATIVE_OK);
  check(written > 0 && written % 2 == 0 && task_frees == 1);
  check(shiroha_native::local_app_data(1, output, 2, &written, fake) == SHIROHA_NATIVE_RESOURCE_LIMIT);
  check(written == 0 && task_frees == 2);
  fail = true;
  check(shiroha_native::local_app_data(1, output, 128, &written, fake) == SHIROHA_NATIVE_UNAVAILABLE);
  check(written == 0 && task_frees == 3 && cleared);
  std::cout << "PASS: offline ABI bounds, fake results, Unicode and cleanup\n";
  return 0;
}
