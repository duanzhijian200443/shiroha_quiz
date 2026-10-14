// Future L1 candidate only. No Batch 2 artifact is modified. Never run without a new batch grant.
#include <windows.h>
#ifndef SHIROHA_PROBE_FAKE_ONLY
#include <psapi.h>
#endif
#include "probe_ledger.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "shiroha_external_native.h"

namespace {

using abi_fn = uint32_t(SHIROHA_NATIVE_CALL*)(void);
using alloc_fn = uint8_t*(SHIROHA_NATIVE_CALL*)(uint64_t);
using free_fn = void(SHIROHA_NATIVE_CALL*)(uint8_t*);
using local_app_data_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint8_t*,
                                                        uint64_t, uint64_t*);
using transform_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, const uint8_t*,
                                                   uint64_t, uint8_t*, uint64_t,
                                                   uint64_t*);
using acquire_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint32_t, uint64_t*);
using validate_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint64_t);
using close_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint64_t);
using assoc_begin_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint64_t, uint8_t*,
                                                     uint64_t, uint64_t*, uint64_t*);
using assoc_commit_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint64_t, uint64_t,
                                                      const uint8_t*, uint64_t);
using assoc_abort_fn = int32_t(SHIROHA_NATIVE_CALL*)(uint32_t, uint64_t, uint64_t);

struct Api {
  HMODULE module = nullptr;
  abi_fn abi = nullptr;
  alloc_fn allocate = nullptr;
  free_fn deallocate = nullptr;
  local_app_data_fn local_app_data = nullptr;
  transform_fn protect = nullptr;
  transform_fn unprotect = nullptr;
  acquire_fn acquire = nullptr;
  validate_fn validate = nullptr;
  close_fn close_owner = nullptr;
  assoc_begin_fn assoc_begin = nullptr;
  assoc_commit_fn assoc_commit = nullptr;
  assoc_abort_fn assoc_abort = nullptr;
};

#ifndef SHIROHA_PROBE_FAKE_ONLY
template <typename T>
bool resolve(HMODULE module, const char* name, T& target) {
  const auto symbol = GetProcAddress(module, name);
  if (symbol == nullptr) {
    std::printf("symbol_missing name=%s ok=0\n", name);
    return false;
  }
  static_assert(sizeof(T) == sizeof(symbol), "Windows function pointer size");
  std::memcpy(&target, &symbol, sizeof(target));
  return true;
}

bool load_api(const wchar_t* path, Api& api) {
  api = Api{};
  api.module = LoadLibraryW(path);
  if (api.module == nullptr) {
    std::printf("load path=failed ok=0\n");
    return false;
  }
  return resolve(api.module, "shiroha_native_abi_version", api.abi) &&
         resolve(api.module, "shiroha_native_buffer_alloc", api.allocate) &&
         resolve(api.module, "shiroha_native_buffer_free", api.deallocate) &&
         resolve(api.module, "shiroha_native_local_app_data", api.local_app_data) &&
         resolve(api.module, "shiroha_native_dpapi_protect", api.protect) &&
         resolve(api.module, "shiroha_native_dpapi_unprotect", api.unprotect) &&
         resolve(api.module, "shiroha_native_owner_acquire", api.acquire) &&
         resolve(api.module, "shiroha_native_owner_validate", api.validate) &&
         resolve(api.module, "shiroha_native_owner_close", api.close_owner) &&
         resolve(api.module, "shiroha_native_association_begin", api.assoc_begin) &&
         resolve(api.module, "shiroha_native_association_commit", api.assoc_commit) &&
         resolve(api.module, "shiroha_native_association_abort", api.assoc_abort);
}

#endif

struct OwnerRelease {
  const Api& api;
  uint64_t& owner;
  ProbeLedger& ledger;
  bool close() noexcept {
    if (!owner) return true;
    const auto token = owner;
    owner = 0;
    return ledger.release([&] { return api.close_owner(SHIROHA_NATIVE_ABI_VERSION, token); });
  }
  ~OwnerRelease() noexcept { close(); }
};

// Deterministic synthetic bytes; never real data or secrets.
uint8_t pattern_byte(std::size_t index) {
  return static_cast<uint8_t>((index * 131u + 17u) & 0xFFu);
}

bool same_bytes(const std::vector<uint8_t>& a, std::size_t length,
                const std::vector<uint8_t>& b) {
  if (a.size() < length || b.size() < length) return false;
  for (std::size_t i = 0; i < length; ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

#ifndef SHIROHA_PROBE_FAKE_ONLY
void usage() {
  std::printf(
      "usage: l1_assoc_probe <symbols|abi|assoc|bridge-denied> <dll>\n");
}

#endif

int run_assoc(const Api& api, ProbeLedger& ledger) {
  std::vector<uint8_t> payload64(64), payload96(96);
  std::vector<uint8_t> blob1(SHIROHA_NATIVE_MAX_BYTES);
  std::vector<uint8_t> blob2(SHIROHA_NATIVE_MAX_BYTES);
  std::vector<uint8_t> readbuf(SHIROHA_NATIVE_MAX_BYTES);
  for (std::size_t i = 0; i < payload64.size(); ++i) payload64[i] = pattern_byte(i);
  for (std::size_t i = 0; i < payload96.size(); ++i) payload96[i] = pattern_byte(i + 100);

  uint64_t owner = 0;
  OwnerRelease release{api, owner, ledger};
  const auto acquired = ledger.invoke("acquire", [&] { return api.acquire(SHIROHA_NATIVE_ABI_VERSION, SHIROHA_NATIVE_APP, &owner); });
  std::printf("owner acquire=%d tokenpos=%d\n", static_cast<int>(acquired),
              owner != 0 ? 1 : 0);
  if (!ledger.record("acquire", acquired, SHIROHA_NATIVE_OK, owner != 0)) return 10;

  uint64_t n1 = 0;
  const auto p1 = ledger.invoke("protect", [&] { return api.protect(SHIROHA_NATIVE_ABI_VERSION, payload64.data(),
                              payload64.size(), blob1.data(), blob1.size(), &n1); });
  std::printf("blob protect=%d bytes=%llu\n", static_cast<int>(p1),
              static_cast<unsigned long long>(n1));

  if (!ledger.record("protect", p1, SHIROHA_NATIVE_OK, n1 > 0 && n1 <= blob1.size())) return 10;

  uint64_t written = 0, ticket1 = 0;
  const auto begin1 = ledger.invoke("begin1", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                      readbuf.data(), readbuf.size(), &written, &ticket1); });
  std::printf("begin1 status=%d written=%llu ticketpos=%d\n",
              static_cast<int>(begin1), static_cast<unsigned long long>(written),
              ticket1 != 0 ? 1 : 0);

  if (!ledger.record("begin1", begin1, SHIROHA_NATIVE_MISSING, written == 0 && ticket1 != 0)) return 10;

  // One native transaction per App owner: a second begin while the first ticket
  // is retained must deny without disturbing the retained transaction.
  uint64_t w2 = 0, ticket2 = 0;
  const auto begin2 = ledger.invoke("begin2", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                      readbuf.data(), readbuf.size(), &w2, &ticket2); });
  std::printf("begin2 status=%d written=%llu ticketpos=%d\n",
              static_cast<int>(begin2), static_cast<unsigned long long>(w2),
              ticket2 != 0 ? 1 : 0);

  if (!ledger.record("begin2", begin2, SHIROHA_NATIVE_RESOURCE_LIMIT, w2 == 0 && ticket2 == 0)) return 10;

  const auto commit1 = ledger.invoke("commit1", [&] { return api.assoc_commit(SHIROHA_NATIVE_ABI_VERSION, owner, ticket1,
                                        blob1.data(), n1); });
  std::printf("commit1 status=%d\n", static_cast<int>(commit1));

  if (!ledger.record("commit1", commit1, SHIROHA_NATIVE_OK, true)) return 10;

  uint64_t w3 = 0, ticket3 = 0;
  const auto begin3 = ledger.invoke("begin3", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                      readbuf.data(), readbuf.size(), &w3, &ticket3); });
  int match3 = 0;
  if (begin3 == SHIROHA_NATIVE_OK && w3 == n1 && same_bytes(readbuf, static_cast<std::size_t>(w3), blob1)) {
    match3 = 1;
  }
  std::printf("begin3 status=%d readbytes=%llu match=%d\n",
              static_cast<int>(begin3), static_cast<unsigned long long>(w3), match3);

  if (!ledger.record("begin3", begin3, SHIROHA_NATIVE_OK, match3 == 1 && ticket3 != 0)) return 10;

  const auto abort1 = ledger.invoke("abort1", [&] { return api.assoc_abort(SHIROHA_NATIVE_ABI_VERSION, owner, ticket3); });
  std::printf("abort1 status=%d\n", static_cast<int>(abort1));

  if (!ledger.record("abort1", abort1, SHIROHA_NATIVE_OK, true)) return 10;

  uint64_t n2 = 0;
  const auto p2 = ledger.invoke("protect2", [&] { return api.protect(SHIROHA_NATIVE_ABI_VERSION, payload96.data(),
                              payload96.size(), blob2.data(), blob2.size(), &n2); });
  std::printf("blob2 protect=%d bytes=%llu\n", static_cast<int>(p2),
              static_cast<unsigned long long>(n2));

  if (!ledger.record("protect2", p2, SHIROHA_NATIVE_OK, n2 > 0 && n2 <= blob2.size())) return 10;

  uint64_t w4 = 0, ticket4 = 0;
  const auto begin4 = ledger.invoke("begin4", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                      readbuf.data(), readbuf.size(), &w4, &ticket4); });
  int match4 = 0;
  if (begin4 == SHIROHA_NATIVE_OK && w4 == n1 && same_bytes(readbuf, static_cast<std::size_t>(w4), blob1)) {
    match4 = 1;
  }
  std::printf("begin4 status=%d readbytes=%llu match=%d\n",
              static_cast<int>(begin4), static_cast<unsigned long long>(w4), match4);

  if (!ledger.record("begin4", begin4, SHIROHA_NATIVE_OK, match4 == 1 && ticket4 != 0)) return 10;

  const auto commit2 = ledger.invoke("commit2", [&] { return api.assoc_commit(SHIROHA_NATIVE_ABI_VERSION, owner, ticket4,
                                        blob2.data(), n2); });
  std::printf("commit2 status=%d\n", static_cast<int>(commit2));

  if (!ledger.record("commit2", commit2, SHIROHA_NATIVE_OK, true)) return 10;

  uint64_t w5 = 0, ticket5 = 0;
  const auto begin5 = ledger.invoke("begin5", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                      readbuf.data(), readbuf.size(), &w5, &ticket5); });
  int match5 = 0;
  if (begin5 == SHIROHA_NATIVE_OK && w5 == n2 && same_bytes(readbuf, static_cast<std::size_t>(w5), blob2)) {
    match5 = 1;
  }
  std::printf("begin5 status=%d readbytes=%llu match=%d\n",
              static_cast<int>(begin5), static_cast<unsigned long long>(w5), match5);

  if (!ledger.record("begin5", begin5, SHIROHA_NATIVE_OK, match5 == 1 && ticket5 != 0)) return 10;

  const auto abort2 = ledger.invoke("abort2", [&] { return api.assoc_abort(SHIROHA_NATIVE_ABI_VERSION, owner, ticket5); });
  std::printf("abort2 status=%d\n", static_cast<int>(abort2));

  if (!ledger.record("abort2", abort2, SHIROHA_NATIVE_OK, true)) return 10;

  // The consumed ticket must be rejected; this call must not touch the file.
  const auto stale = ledger.invoke("stale_commit", [&] { return api.assoc_commit(SHIROHA_NATIVE_ABI_VERSION, owner, ticket5,
                                      blob1.data(), n1); });
  std::printf("stale_commit status=%d\n", static_cast<int>(stale));

  if (!ledger.record("stale_commit", stale, SHIROHA_NATIVE_INVALID_INPUT, true)) return 10;
  return release.close() ? 0 : 10;
}

int run_bridge_denied(const Api& api, ProbeLedger& ledger) {
  std::vector<uint8_t> readbuf(SHIROHA_NATIVE_MAX_BYTES);
  uint64_t owner = 0;
  OwnerRelease release{api, owner, ledger};
  const auto acquired = ledger.invoke("acquire", [&] { return api.acquire(SHIROHA_NATIVE_ABI_VERSION, SHIROHA_NATIVE_BRIDGE, &owner); });
  std::printf("bridge acquire=%d tokenpos=%d\n", static_cast<int>(acquired),
              owner != 0 ? 1 : 0);
  if (!ledger.record("acquire", acquired, SHIROHA_NATIVE_OK, owner != 0)) return 10;
  uint64_t written = 0, ticket = 0;
  const auto begin = ledger.invoke("bridge_begin", [&] { return api.assoc_begin(SHIROHA_NATIVE_ABI_VERSION, owner,
                                     readbuf.data(), readbuf.size(), &written, &ticket); });
  std::printf("bridge_begin status=%d written=%llu ticketpos=%d\n",
              static_cast<int>(begin), static_cast<unsigned long long>(written),
              ticket != 0 ? 1 : 0);
  if (!ledger.record("bridge_begin", begin, SHIROHA_NATIVE_UNAVAILABLE, written == 0 && ticket == 0)) return 10;
  return release.close() ? 0 : 10;
}

}  // namespace

#ifndef SHIROHA_PROBE_FAKE_ONLY
bool sample_resources(ProbeLedger& ledger) noexcept {
  PROCESS_MEMORY_COUNTERS memory{};
  memory.cb = sizeof(memory);
  DWORD handles = 0;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory)) ||
      !GetProcessHandleCount(GetCurrentProcess(), &handles)) return false;
  return ledger.resources(memory.PeakWorkingSetSize, memory.PeakPagefileUsage, handles);
}

int wmain(int argc, wchar_t** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0); // Preserve last attempt if a process stalls.
  if (argc != 3) { usage(); return 64; }
  const std::wstring mode = argv[1];
  if (mode != L"symbols" && mode != L"abi" && mode != L"assoc" && mode != L"bridge-denied") return 64;
  ProbeLedger ledger(mode == L"assoc" ? ProbeLedger::app : mode == L"bridge-denied" ? ProbeLedger::bridge : ProbeLedger::none);
  ledger.abi_planned = mode != L"symbols";
  ledger.sample = sample_resources;
  int result = 10;
  try {
    if (!ledger.observe()) return 10;
    Api api;
    if (!load_api(argv[2], api)) { ledger.stop("load_or_symbol", -1); ledger.observe(); return 3; }
    if (mode == L"symbols") { std::printf("symbols resolved=12 ok=1\n"); return ledger.observe() ? 0 : 10; }
    const auto version = ledger.invoke("abi", [&] { return api.abi(); });
    if (!ledger.record("abi", static_cast<int>(version), SHIROHA_NATIVE_ABI_VERSION, true)) return 2;
    if (mode == L"abi") result = 0;
    else if (mode == L"assoc") result = run_assoc(api, ledger);
    else result = run_bridge_denied(api, ledger);
  } catch (...) { ledger.stop("exception", -1); }
  return result;
}
#endif
