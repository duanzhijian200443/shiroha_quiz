// Compile-only at L0. --run-once requires a separate exact real-test grant.
#if !defined(SHIROHA_P20_DIAGNOSTIC_BUILD)
#error P20 minimal real-test driver must never be built as production
#endif
#include "diagnostics/p20_test_root.h"
#include "shiroha_external_native.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>

namespace {
constexpr auto abi = SHIROHA_NATIVE_ABI_VERSION;
bool expect(const char* stage, int32_t status, int32_t wanted, bool shape = true) {
  const bool ok = status == wanted && shape;
  std::printf("stage=%s status=%d match=%d\n", stage, static_cast<int>(status), ok ? 1 : 0);
  return ok;
}
struct Owner {
  uint64_t value = 0;
  bool close() noexcept {
    if (!value) return true;
    const auto token = value;
    value = 0; // Exactly one attempt, including failure/unknown closure.
    return expect("owner_close", shiroha_native_owner_close(abi, token), SHIROHA_NATIVE_OK);
  }
  ~Owner() noexcept { close(); }
};
bool equal(const std::vector<uint8_t>& actual, uint64_t length,
           const std::vector<uint8_t>& wanted, uint64_t expected) {
  return length == expected && length > 0 && length <= actual.size() && length <= wanted.size() &&
      std::equal(actual.begin(), actual.begin() + static_cast<size_t>(length), wanted.begin());
}
template<size_t N>
bool readback(const char* stage, uint64_t owner, const std::vector<uint8_t>& blob,
              uint64_t blob_length, const std::array<uint8_t, N>& payload,
              std::vector<uint8_t>& bytes, std::vector<uint8_t>& plain) {
  uint64_t written = 0, ticket = 0;
  const auto read = shiroha_native_association_begin(abi, owner, bytes.data(), bytes.size(), &written, &ticket);
  if (!expect(stage, read, SHIROHA_NATIVE_OK, ticket != 0 && equal(bytes, written, blob, blob_length))) return false;
  uint64_t decoded = 0;
  const auto unprotect = shiroha_native_dpapi_unprotect(abi, bytes.data(), written, plain.data(), plain.size(), &decoded);
  if (!expect("readback_decrypt", unprotect, SHIROHA_NATIVE_OK,
      decoded == N && std::equal(payload.begin(), payload.end(), plain.begin()))) return false;
  return expect("readback_abort", shiroha_native_association_abort(abi, owner, ticket), SHIROHA_NATIVE_OK);
}
int run() {
  if (shiroha_native_abi_version() != abi) return 10;
  // No reuse/enumeration/cleanup of an existing root. Create exactly the compiled
  // ancestor once; the unchanged owner creates its fixed children beneath it.
  std::wstring root;
  if (!expect("root", shiroha_native::resolve_object_root(root, nullptr), SHIROHA_NATIVE_OK)) return 10;
  if (!CreateDirectoryW(root.c_str(), nullptr)) { std::printf("STOP stage=root_create\n"); return 10; }
  Owner owner;
  const auto acquired = shiroha_native_owner_acquire(abi, SHIROHA_NATIVE_APP, &owner.value);
  if (!expect("owner_acquire", acquired, SHIROHA_NATIVE_OK, owner.value != 0)) return 10;
  std::array<uint8_t, 64> a{};
  std::array<uint8_t, 96> b{};
  for (size_t i = 0; i < a.size(); ++i) a[i] = static_cast<uint8_t>((i * 131u + 17u) & 255u);
  for (size_t i = 0; i < b.size(); ++i) b[i] = static_cast<uint8_t>(((i + 100u) * 131u + 17u) & 255u);
  std::vector<uint8_t> blob_a(SHIROHA_NATIVE_MAX_BYTES), blob_b(SHIROHA_NATIVE_MAX_BYTES);
  std::vector<uint8_t> read(SHIROHA_NATIVE_MAX_BYTES), plain(SHIROHA_NATIVE_MAX_BYTES);
  uint64_t length_a = 0, length_b = 0, written = 0, ticket = 0;
  const auto protected_a = shiroha_native_dpapi_protect(abi, a.data(), a.size(), blob_a.data(), blob_a.size(), &length_a);
  if (!expect("protect_a", protected_a, SHIROHA_NATIVE_OK, length_a > 0 && length_a <= blob_a.size())) return 10;
  const auto missing = shiroha_native_association_begin(abi, owner.value, read.data(), read.size(), &written, &ticket);
  if (!expect("missing_a", missing, SHIROHA_NATIVE_MISSING, written == 0 && ticket != 0)) return 10;
  if (!expect("create_a", shiroha_native_association_commit(abi, owner.value, ticket, blob_a.data(), length_a), SHIROHA_NATIVE_OK)) return 10;
  if (!readback("read_a", owner.value, blob_a, length_a, a, read, plain)) return 10;
  const auto protected_b = shiroha_native_dpapi_protect(abi, b.data(), b.size(), blob_b.data(), blob_b.size(), &length_b);
  if (!expect("protect_b", protected_b, SHIROHA_NATIVE_OK, length_b > 0 && length_b <= blob_b.size())) return 10;
  written = 0; ticket = 0;
  const auto existing = shiroha_native_association_begin(abi, owner.value, read.data(), read.size(), &written, &ticket);
  if (!expect("existing_a", existing, SHIROHA_NATIVE_OK, ticket != 0 && equal(read, written, blob_a, length_a))) return 10;
  if (!expect("replace_b", shiroha_native_association_commit(abi, owner.value, ticket, blob_b.data(), length_b), SHIROHA_NATIVE_OK)) return 10;
  if (!readback("read_b", owner.value, blob_b, length_b, b, read, plain)) return 10;
  if (!owner.close()) return 10;
  std::printf("PASS: P20 native create A/read A/replace B/read B; no further mode\n");
  return 0;
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || std::wstring(argv[1]) != L"--run-once") {
    std::printf("DRY RUN: no root access; exact grant required for --run-once\n");
    return argc == 1 ? 0 : 64;
  }
  try { return run(); } catch (...) { std::printf("STOP stage=exception\n"); return 10; }
}
