#define SHIROHA_PROBE_FAKE_ONLY
#include "../diagnostics/association_probe.cpp"
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool value) { if (!value) std::abort(); }
int fail_commit = 0, commit_calls = 0, begin_calls = 0, protect_calls = 0, close_calls = 0;
int after_failure = 0;
int operation_calls = 0, throw_on_call = 0;
bool failed = false, close_failure = false;
uint32_t fake_role = 0;
void operation() {
  if (failed) ++after_failure;
  if (++operation_calls == throw_on_call) {
    failed = true;
    throw std::runtime_error("synthetic invocation exception");
  }
}
int32_t SHIROHA_NATIVE_CALL acquire_fake(uint32_t, uint32_t role, uint64_t* owner) {
  operation(); fake_role = role; *owner = 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL protect_fake(uint32_t, const uint8_t*, uint64_t,
    uint8_t* out, uint64_t, uint64_t* written) {
  operation(); *out = static_cast<uint8_t>(++protect_calls); *written = 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL begin_fake(uint32_t, uint64_t, uint8_t* out,
    uint64_t, uint64_t* written, uint64_t* ticket) {
  operation(); ++begin_calls; *written = 0; *ticket = 0;
  if (fake_role == SHIROHA_NATIVE_BRIDGE) return SHIROHA_NATIVE_UNAVAILABLE;
  if (begin_calls == 2) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  *ticket = static_cast<uint64_t>(begin_calls);
  if (begin_calls == 1) return SHIROHA_NATIVE_MISSING;
  *written = 1; *out = begin_calls == 5 ? 2 : 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL commit_fake(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t) {
  operation(); ++commit_calls;
  if (commit_calls == fail_commit) { failed = true; return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
  return commit_calls == 3 ? SHIROHA_NATIVE_INVALID_INPUT : SHIROHA_NATIVE_OK;
}
int32_t SHIROHA_NATIVE_CALL abort_fake(uint32_t, uint64_t, uint64_t) { operation(); return 0; }
int32_t SHIROHA_NATIVE_CALL close_fake(uint32_t, uint64_t) {
  ++close_calls; return close_failure ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK;
}
}
int main() {
  Api api;
  api.acquire = acquire_fake; api.protect = protect_fake; api.assoc_begin = begin_fake;
  api.assoc_commit = commit_fake; api.assoc_abort = abort_fake; api.close_owner = close_fake;
  for (const bool bad_close : {false, true}) {
    for (int failure = 0; failure <= 2; ++failure) {
      fail_commit = failure; commit_calls = begin_calls = protect_calls = close_calls = after_failure = 0;
      failed = false; close_failure = bad_close;
      ProbeLedger ledger(ProbeLedger::app);
      const auto result = run_assoc(api, ledger);
      require(result == (failure || bad_close ? 10 : 0));
      require(after_failure == 0 && close_calls == 1);
      require(commit_calls == (failure ? failure : 3));
      require(begin_calls == (failure == 1 ? 2 : failure == 2 ? 4 : 5));
      require(protect_calls == (failure == 1 ? 1 : 2));
      require(ledger.commits == static_cast<unsigned>(commit_calls) && ledger.closes == 1);
      if (failure == 1) require(ledger.done == 31u); // Exactly first five steps.
    }
  }
  // The real entry point catches exceptions after RAII closes the owner.
  // Inject each post-acquire call boundary without loading any DLL.
  for (int boundary = 2; boundary <= 13; ++boundary) {
    throw_on_call = boundary; operation_calls = 0;
    fail_commit = commit_calls = begin_calls = protect_calls = close_calls = after_failure = 0;
    failed = close_failure = false;
    ProbeLedger ledger(ProbeLedger::app);
    bool caught = false;
    try { run_assoc(api, ledger); }
    catch (...) { caught = true; ledger.stop("exception", -1); }
    require(caught && operation_calls == boundary && after_failure == 0 && close_calls == 1);
  }
  throw_on_call = 0;
  failed = close_failure = false; begin_calls = close_calls = 0;
  ProbeLedger bridge_ledger(ProbeLedger::bridge);
  require(run_bridge_denied(api, bridge_ledger) == 0 && begin_calls == 1 && close_calls == 1);
  ProbeLedger budget(ProbeLedger::none);
  require(budget.resources(10, 20, 4));
  require(!budget.resources(64ull * 1024 * 1024 + 1, 20, 5));
  require(!budget.resources(10, 64ull * 1024 * 1024 + 1, 5));
  require(!budget.resources(10, 20, 129));
  std::cout << "PASS: fake-only probe stops after first unknown; only one owner close allowed\n";
}
