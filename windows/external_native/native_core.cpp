#include "native_core.h"

#include <cstdlib>
#include <cstring>
#include <limits>

namespace {
struct alignas(8) Allocation {
  uint64_t capacity;
};

bool bounded(uint64_t length) noexcept {
  return length > 0 && length <= SHIROHA_NATIVE_MAX_BYTES;
}

bool span(const void* pointer, uint64_t length) noexcept {
  if (!pointer || !bounded(length)) return false;
  const auto start = reinterpret_cast<uintptr_t>(pointer);
  return start <= (std::numeric_limits<uintptr_t>::max)() - length;
}

bool overlaps(const void* a, uint64_t a_size, const void* b,
              uint64_t b_size) noexcept {
  const auto x = reinterpret_cast<uintptr_t>(a);
  const auto y = reinterpret_cast<uintptr_t>(b);
  return x < y + b_size && y < x + a_size;
}

int32_t prepare(uint32_t version, uint8_t* output, uint64_t capacity,
                uint64_t* written) noexcept {
  // Extent/liveness remains the trusted caller's C memory precondition.
  if (!span(written, sizeof(*written)) ||
      reinterpret_cast<uintptr_t>(written) % alignof(uint64_t) != 0) {
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  if (span(output, capacity) &&
      overlaps(output, capacity, written, sizeof(*written))) {
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  *written = 0;
  if (!span(output, capacity)) return SHIROHA_NATIVE_INVALID_INPUT;
  SecureZeroMemory(output, static_cast<SIZE_T>(capacity));
  // ABI 1 memory operations remain callable with unchanged P18 semantics.
  if (version != 1u && version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  return SHIROHA_NATIVE_OK;
}

struct LocalResult {
  DATA_BLOB blob{};
  const shiroha_native::Operations& ops;
  ~LocalResult() noexcept {
    if (blob.pbData) {
      // Win32 owns allocation extent cbData even on a failed call. Wipe all
      // helper-owned results (including decrypted plaintext), then LocalFree.
      SecureZeroMemory(blob.pbData, blob.cbData);
      ops.free_local(blob.pbData);
    }
  }
};

struct TaskResult {
  PWSTR path = nullptr;
  const shiroha_native::Operations& ops;
  ~TaskResult() noexcept {
    if (path) ops.free_task(path);  // CoTaskMemFree on success and failure.
  }
};
}  // namespace

uint32_t SHIROHA_NATIVE_CALL shiroha_native_abi_version(void) {
  return SHIROHA_NATIVE_ABI_VERSION;
}

uint8_t* SHIROHA_NATIVE_CALL shiroha_native_buffer_alloc(uint64_t capacity) {
  if (!bounded(capacity) ||
      capacity > (std::numeric_limits<size_t>::max)() - sizeof(Allocation)) {
    return nullptr;
  }
  auto* block = static_cast<Allocation*>(
      std::calloc(1, sizeof(Allocation) + static_cast<size_t>(capacity)));
  if (!block) return nullptr;
  block->capacity = capacity;
  return reinterpret_cast<uint8_t*>(block + 1);
}

void SHIROHA_NATIVE_CALL shiroha_native_buffer_free(uint8_t* buffer) {
  if (!buffer) return;
  auto* block = reinterpret_cast<Allocation*>(buffer) - 1;
  SecureZeroMemory(buffer, static_cast<SIZE_T>(block->capacity));
  SecureZeroMemory(block, sizeof(Allocation));
  std::free(block);
}

namespace shiroha_native {
int32_t transform(uint32_t version, const uint8_t* input, uint64_t length,
                  uint8_t* output, uint64_t capacity, uint64_t* written,
                  bool decrypt, const Operations& ops) noexcept {
  // Validate input and aliases before clearing output (never erase input).
  if (!span(input, length) ||
      (span(output, capacity) && overlaps(input, length, output, capacity)) ||
      (span(written, sizeof(*written)) &&
       overlaps(input, length, written, sizeof(*written)))) {
    const auto valid_count = span(written, sizeof(*written)) &&
        reinterpret_cast<uintptr_t>(written) % alignof(uint64_t) == 0;
    const auto output_count_alias = span(output, capacity) && valid_count &&
        overlaps(output, capacity, written, sizeof(*written));
    const auto input_count_alias = span(input, length) && valid_count &&
        overlaps(input, length, written, sizeof(*written));
    if (valid_count && !input_count_alias && !output_count_alias) {
      *written = 0;
    }
    if (span(output, capacity) && !output_count_alias &&
        (!span(input, length) || !overlaps(input, length, output, capacity))) {
      SecureZeroMemory(output, static_cast<SIZE_T>(capacity));
    }
    return SHIROHA_NATIVE_INVALID_INPUT;
  }
  const auto ready = prepare(version, output, capacity, written);
  if (ready != SHIROHA_NATIVE_OK) return ready;
  DATA_BLOB source{static_cast<DWORD>(length), const_cast<BYTE*>(input)};
  LocalResult result{{}, ops};
  const auto success = decrypt ? ops.unprotect(&source, &result.blob)
                               : ops.protect(&source, &result.blob);
  // No decrypt failure becomes Missing or triggers recovery. OS errors are
  // deliberately not exported: unwrap failure is dataCorrupt, wrap unavailable.
  if (!success) return decrypt ? SHIROHA_NATIVE_DATA_CORRUPT
                               : SHIROHA_NATIVE_UNAVAILABLE;
  if (!result.blob.pbData || result.blob.cbData == 0) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  if (result.blob.cbData > capacity) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  std::memcpy(output, result.blob.pbData, result.blob.cbData);
  *written = result.blob.cbData;
  return SHIROHA_NATIVE_OK;
}

int32_t local_app_data(uint32_t version, uint8_t* output, uint64_t capacity,
                       uint64_t* written, const Operations& ops) noexcept {
  const auto ready = prepare(version, output, capacity, written);
  if (ready != SHIROHA_NATIVE_OK) return ready;
  TaskResult result{nullptr, ops};
  if (FAILED(ops.known_folder(&result.path))) return SHIROHA_NATIVE_UNAVAILABLE;
  if (!result.path) return SHIROHA_NATIVE_DATA_CORRUPT;
  static_assert(sizeof(WCHAR) == 2, "Windows UTF-16 required");
  size_t units = 0;
  while (units < SHIROHA_NATIVE_MAX_BYTES / sizeof(WCHAR) && result.path[units]) {
    ++units;
  }
  if (units == 0 || units == SHIROHA_NATIVE_MAX_BYTES / sizeof(WCHAR)) {
    return SHIROHA_NATIVE_DATA_CORRUPT;
  }
  const auto bytes = units * sizeof(WCHAR);
  if (bytes > capacity) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  std::memcpy(output, result.path, bytes);
  *written = bytes;
  return SHIROHA_NATIVE_OK;
}
}  // namespace shiroha_native
