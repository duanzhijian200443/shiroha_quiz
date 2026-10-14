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
bool failed = false, close_failure = false, close_exception = false;
int fail_status_at = 0, status_calls = 0;
int bad_shape_at = 0;
unsigned sample_calls = 0, fail_sample_at = 0;
uint32_t fake_role = 0;
void operation() {
  if (failed) ++after_failure;
  if (++operation_calls == throw_on_call) {
    failed = true;
    throw std::runtime_error("synthetic invocation exception");
  }
}
bool status_failure() {
  if (operation_calls == fail_status_at) { failed = true; ++status_calls; return true; }
  return false;
}
bool resource_fake(ProbeLedger& ledger) noexcept {
  if (++sample_calls == fail_sample_at) return false;
  return ledger.resources(10, 20, 4);
}
void reset() {
  fail_commit = commit_calls = begin_calls = protect_calls = close_calls = after_failure = 0;
  operation_calls = throw_on_call = fail_status_at = status_calls = bad_shape_at = 0;
  sample_calls = fail_sample_at = 0;
  failed = close_failure = close_exception = false;
}
int32_t SHIROHA_NATIVE_CALL acquire_fake(uint32_t, uint32_t role, uint64_t* owner) {
  operation(); if (status_failure()) return SHIROHA_NATIVE_UNAVAILABLE;
  fake_role = role; *owner = bad_shape_at == operation_calls ? 0 : 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL protect_fake(uint32_t, const uint8_t*, uint64_t,
    uint8_t* out, uint64_t, uint64_t* written) {
  operation(); if (status_failure()) return SHIROHA_NATIVE_UNAVAILABLE;
  *out = static_cast<uint8_t>(++protect_calls); *written = bad_shape_at == operation_calls ? 0 : 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL begin_fake(uint32_t, uint64_t, uint8_t* out,
    uint64_t, uint64_t* written, uint64_t* ticket) {
  operation(); if (status_failure()) return SHIROHA_NATIVE_UNAVAILABLE;
  ++begin_calls; *written = 0; *ticket = 0;
  if (fake_role == SHIROHA_NATIVE_BRIDGE) {
    if (bad_shape_at == operation_calls) *ticket = 1;
    return SHIROHA_NATIVE_UNAVAILABLE;
  }
  if (begin_calls == 2) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  *ticket = bad_shape_at == operation_calls ? 0 : static_cast<uint64_t>(begin_calls);
  if (begin_calls == 1) return SHIROHA_NATIVE_MISSING;
  *written = 1; *out = begin_calls == 5 ? 2 : 1; return 0;
}
int32_t SHIROHA_NATIVE_CALL commit_fake(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t) {
  operation(); if (status_failure()) return SHIROHA_NATIVE_UNAVAILABLE;
  ++commit_calls;
  if (commit_calls == fail_commit) { failed = true; return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
  return commit_calls == 3 ? SHIROHA_NATIVE_INVALID_INPUT : SHIROHA_NATIVE_OK;
}
int32_t SHIROHA_NATIVE_CALL abort_fake(uint32_t, uint64_t, uint64_t) { operation(); return status_failure() ? SHIROHA_NATIVE_UNAVAILABLE : 0; }
int32_t SHIROHA_NATIVE_CALL close_fake(uint32_t, uint64_t) {
  ++close_calls;
  if (close_exception) throw std::runtime_error("synthetic close exception");
  return close_failure ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK;
}
}
int main() {
  Api api;
  api.acquire = acquire_fake; api.protect = protect_fake; api.assoc_begin = begin_fake;
  api.assoc_commit = commit_fake; api.assoc_abort = abort_fake; api.close_owner = close_fake;
  for (const bool bad_close : {false, true}) {
    for (int failure = 0; failure <= 2; ++failure) {
      reset(); fail_commit = failure; close_failure = bad_close;
      ProbeLedger ledger(ProbeLedger::app);
      const auto result = run_assoc(api, ledger);
      require(result == (failure || bad_close ? 10 : 0));
      require(after_failure == 0 && close_calls == 1);
      require(commit_calls == (failure ? failure : 3));
      require(begin_calls == (failure == 1 ? 2 : failure == 2 ? 4 : 5));
      require(protect_calls == (failure == 1 ? 1 : 2));
      require(ledger.commits == static_cast<unsigned>(commit_calls) && ledger.closes == 1);
      require(ledger.total_attempted() == static_cast<unsigned>(operation_calls + close_calls));
      require(ledger.returned == ledger.total_attempted() && ledger.completed == ledger.returned);
      if (!failure && !bad_close) require(ledger.accepted == 14 && ledger.successful == 11);
      if (failure) require(std::strcmp(ledger.first_failure, failure == 1 ? "commit1" : "commit2") == 0 && ledger.first_status == 7);
      if (failure == 1) require(ledger.done == 31u); // Exactly first five steps.
    }
  }
  // Every throwing/status boundary, including acquire; close failure cannot
  // replace the first failure, and a throwing close is attempted exactly once.
  for (int boundary = 1; boundary <= 13; ++boundary) {
    for (int close_mode = 0; close_mode < 3; ++close_mode) {
      reset(); throw_on_call = boundary;
      close_failure = close_mode == 1; close_exception = close_mode == 2;
      ProbeLedger ledger(ProbeLedger::app);
      bool caught = false;
      try { run_assoc(api, ledger); }
      catch (...) { caught = true; ledger.stop("exception", -1); }
      const auto cleanup = boundary == 1 ? 0 : 1;
      require(caught && operation_calls == boundary && after_failure == 0 && close_calls == cleanup);
      require(ledger.total_attempted() == static_cast<unsigned>(boundary + cleanup));
      require(ledger.returned == static_cast<unsigned>(boundary - 1 + (close_mode == 2 ? 0 : cleanup)));
      require(ledger.completed == ledger.returned && ledger.first_status == -1);
      require(std::strcmp(ledger.first_failure, ProbeLedger::steps[boundary - 1]) == 0);
      require(ledger.done == (1u << boundary) - 1);
      require(ledger.completed_steps == (1u << (boundary - 1)) - 1);
    }
    reset(); fail_status_at = boundary; close_failure = true;
    ProbeLedger status_ledger(ProbeLedger::app);
    require(run_assoc(api, status_ledger) == 10 && status_calls == 1 && after_failure == 0);
    require(operation_calls == boundary && close_calls == (boundary == 1 ? 0 : 1));
    require(status_ledger.returned == status_ledger.total_attempted());
    require(std::strcmp(status_ledger.first_failure, ProbeLedger::steps[boundary - 1]) == 0);
    require(status_ledger.first_status == SHIROHA_NATIVE_UNAVAILABLE);
  }
  // Positive status with invalid owner/blob/ticket is still STOP, no next step.
  for (const auto boundary : {1, 2, 3, 6, 8, 9, 11}) {
    reset(); bad_shape_at = boundary;
    ProbeLedger ledger(ProbeLedger::app);
    require(run_assoc(api, ledger) == 10 && operation_calls == boundary);
    require(close_calls == (boundary == 1 ? 0 : 1));
    require(std::strcmp(ledger.first_failure, ProbeLedger::steps[boundary - 1]) == 0);
  }
  // Sampling failure before business, after each call and after cleanup.
  for (unsigned observation = 1; observation <= 15; ++observation) {
    reset(); fail_sample_at = observation;
    ProbeLedger ledger(ProbeLedger::app); ledger.sample = resource_fake;
    const auto result = ledger.observe() ? run_assoc(api, ledger) : 10;
    require(result == 10 && ledger.observation_failures == 1);
    require(std::strcmp(ledger.first_failure, "resource_observation_or_budget") == 0);
    require(operation_calls == static_cast<int>(observation == 1 ? 0 : observation == 15 ? 13 : observation - 1));
    require(close_calls == (observation == 1 ? 0 : 1));
  }
  reset(); fail_commit = 1; fail_sample_at = 6; close_failure = true;
  ProbeLedger secondary(ProbeLedger::app); secondary.sample = resource_fake;
  require(run_assoc(api, secondary) == 10 && secondary.observation_failures == 1);
  require(std::strcmp(secondary.first_failure, "commit1") == 0 && secondary.first_status == 7);
  reset(); close_exception = true;
  ProbeLedger close_throw(ProbeLedger::app);
  require(run_assoc(api, close_throw) == 10 && close_calls == 1);
  require(close_throw.total_attempted() == 14 && close_throw.returned == 13 && close_throw.completed == 13);
  require(std::strcmp(close_throw.first_failure, "owner_close") == 0);
  // The guard itself rejects business invocation and duplicate cleanup.
  int forbidden = 0;
  require(close_throw.invoke("begin1", [&] { ++forbidden; return 0; }) == -1);
  require(!close_throw.release([&] { ++forbidden; return 0; }) && forbidden == 0 && close_throw.closes == 1);
  reset();
  throw_on_call = 0;
  failed = close_failure = false; begin_calls = close_calls = 0;
  ProbeLedger bridge_ledger(ProbeLedger::bridge);
  require(run_bridge_denied(api, bridge_ledger) == 0 && begin_calls == 1 && close_calls == 1);
  require(bridge_ledger.total_attempted() == 3 && bridge_ledger.returned == 3 && bridge_ledger.completed == 3);
  require(bridge_ledger.successful == 2 && bridge_ledger.accepted == 3);
  for (int boundary = 1; boundary <= 2; ++boundary) {
    reset(); throw_on_call = boundary; close_exception = true;
    ProbeLedger ledger(ProbeLedger::bridge);
    try { run_bridge_denied(api, ledger); require(false); } catch (...) {}
    require(operation_calls == boundary && close_calls == (boundary == 1 ? 0 : 1));
    require(ledger.total_attempted() == static_cast<unsigned>(boundary + close_calls));
    require(ledger.returned == static_cast<unsigned>(boundary - 1) && ledger.first_status == -1);
  }
  reset(); bad_shape_at = 2;
  ProbeLedger invalid_bridge(ProbeLedger::bridge);
  require(run_bridge_denied(api, invalid_bridge) == 10 && begin_calls == 1 && close_calls == 1);
  require(std::strcmp(invalid_bridge.first_failure, "bridge_begin") == 0 && invalid_bridge.first_status == 4);
  ProbeLedger abi_ledger(ProbeLedger::none);
  require(abi_ledger.invoke("abi", [] { return 3; }) == 3);
  require(abi_ledger.record("abi", 3, 3, true) && abi_ledger.total_attempted() == 1 && abi_ledger.successful == 1);
  ProbeLedger abi_throw(ProbeLedger::none);
  try { abi_throw.invoke("abi", []() -> int { throw std::runtime_error("synthetic ABI exception"); }); require(false); }
  catch (...) {}
  require(abi_throw.total_attempted() == 1 && abi_throw.returned == 0 && abi_throw.completed == 0);
  ProbeLedger budget(ProbeLedger::none);
  require(budget.resources(10, 20, 4));
  require(!budget.resources(64ull * 1024 * 1024 + 1, 20, 5));
  require(!budget.resources(10, 64ull * 1024 * 1024 + 1, 5));
  require(!budget.resources(10, 20, 129));
  std::cout << "PASS: fake-only attempted/returned/completed/success, first failure, STOP and one close\n";
}
