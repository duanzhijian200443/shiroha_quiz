#ifndef SHIROHA_PROBE_LEDGER_H_
#define SHIROHA_PROBE_LEDGER_H_
#include <cstdint>
#include <cstdio>
#include <cstring>

// This future candidate is not a batch grant. Resource observations run inside
// the probe, not in its parent after exit. Handle maximum is sampled, not an OS
// high-water mark; OS memory peaks include work between samples.
struct ProbeLedger {
  enum Role { none, app, bridge };
  static constexpr const char* steps[] = {"acquire", "protect", "begin1", "begin2", "commit1",
      "begin3", "abort1", "protect2", "begin4", "commit2", "begin5", "abort2", "stale_commit", "bridge_begin"};
  Role role;
  uint32_t done = 0; // Attempted business-step mask, including throwing calls.
  uint32_t returned_steps = 0, completed_steps = 0;
  unsigned returned = 0, completed = 0, successful = 0, accepted = 0;
  unsigned observation_attempts = 0, observation_failures = 0;
  bool abi_planned = false;
  unsigned abi = 0, acquires = 0, protects = 0, begins = 0, commits = 0, aborts = 0, closes = 0;
  bool stopped = false;
  const char* first_failure = "none";
  int first_status = 0;
  bool (*sample)(ProbeLedger&) noexcept = nullptr;
  uint64_t peak_working_set = 0, peak_commit = 0;
  uint32_t handles_first = 0, handles_last = 0, handles_max_sampled = 0, samples = 0;
  explicit ProbeLedger(Role value) noexcept : role(value) {}
  void stop(const char* step, int status) noexcept {
    if (!stopped) {
      first_failure = step; first_status = status;
      std::printf("STOP step=%s status=%d\n", step, status);
    }
    stopped = true;
  }
  bool resources(uint64_t working, uint64_t commit, uint32_t handles) noexcept {
    if (working > peak_working_set) peak_working_set = working;
    if (commit > peak_commit) peak_commit = commit;
    if (samples++ == 0) handles_first = handles;
    handles_last = handles;
    if (handles > handles_max_sampled) handles_max_sampled = handles;
    // Candidate ceilings must be included explicitly in any future batch grant.
    return working <= 64ull * 1024 * 1024 && commit <= 64ull * 1024 * 1024 && handles <= 128;
  }
  bool observe() noexcept {
    if (sample) {
      ++observation_attempts;
      if (!sample(*this)) {
        ++observation_failures;
        std::printf("resource_observation_failed occurrence=%u\n", observation_failures);
        stop("resource_observation_or_budget", -1);
      }
    }
    return !stopped;
  }
  void attempted(const char* step) noexcept {
    if (std::strcmp(step, "abi") == 0) ++abi;
    else {
      for (unsigned i = 0; i < 14; ++i) if (std::strcmp(step, steps[i]) == 0) done |= 1u << i;
      if (std::strcmp(step, "acquire") == 0) ++acquires;
      else if (std::strncmp(step, "protect", 7) == 0) ++protects;
      else if (std::strncmp(step, "begin", 5) == 0 || std::strcmp(step, "bridge_begin") == 0) ++begins;
      else if (std::strncmp(step, "abort", 5) == 0) ++aborts;
      else ++commits;
    }
    std::printf("attempt step=%s total=%u\n", step, total_attempted());
  }
  template <typename Call>
  int invoke(const char* step, Call call) {
    if (stopped) return -1; // No business call after the first STOP.
    attempted(step);
    try {
      const auto status = static_cast<int>(call());
      ++returned;
      for (unsigned i = 0; i < 14; ++i)
        if (std::strcmp(step, steps[i]) == 0) returned_steps |= 1u << i;
      return status;
    }
    catch (...) {
      stop(step, -1);
      std::printf("not_returned step=%s exception=1\n", step);
      observe();
      throw;
    } // Preserve failure before RAII close.
  }
  bool record(const char* step, int status, int expected, bool valid) noexcept {
    ++completed; // Status and output-shape checks completed, even on failure.
    for (unsigned i = 0; i < 14; ++i)
      if (std::strcmp(step, steps[i]) == 0) completed_steps |= 1u << i;
    // ABI returns a version; status-bearing calls succeed only with status 0.
    if (std::strcmp(step, "abi") == 0 ? status == expected : status == 0) ++successful;
    if (status == expected && valid) ++accepted;
    std::printf("checked step=%s actual=%d expected=%d shape=%d\n", step, status, expected, valid ? 1 : 0);
    if (status != expected || !valid) stop(step, status);
    return observe();
  }
  template <typename Call>
  bool release(Call call) noexcept {
    if (closes) { stop("duplicate_owner_close", -1); return false; }
    ++closes; // Count BEFORE calling; exception is attempted, never returned.
    std::printf("attempt step=owner_close total=%u\n", total_attempted());
    try {
      const auto status = static_cast<int>(call());
      ++returned; ++completed;
      if (status == 0) { ++successful; ++accepted; }
      std::printf("cleanup owner_close=%d\n", status);
      if (status != 0) stop("owner_close", status);
    } catch (...) {
      stop("owner_close", -1);
      std::printf("not_returned step=owner_close exception=1\n");
    }
    return observe();
  }
  unsigned total_attempted() const noexcept {
    return abi + acquires + protects + begins + commits + aborts + closes;
  }
  ~ProbeLedger() noexcept {
    std::printf("summary attempted=%u returned=%u completed=%u successful=%u accepted=%u first_failure=%s actual_status=%d stopped=%d\n",
        total_attempted(), returned, completed, successful, accepted,
        first_failure, first_status, stopped ? 1 : 0);
    std::printf("counts abi=%u acquire=%u protect=%u app_begin=%u bridge_begin=%u commit=%u abort=%u close=%u\n",
        abi, acquires, protects, role == app ? begins : 0, role == bridge ? begins : 0, commits, aborts, closes);
    std::printf("resources observations=%u observation_failures=%u samples=%u peak_working_set=%llu peak_commit=%llu handles_first=%u handles_last=%u handles_max_sampled=%u\n",
        observation_attempts, observation_failures, samples, static_cast<unsigned long long>(peak_working_set), static_cast<unsigned long long>(peak_commit),
        handles_first, handles_last, handles_max_sampled);
    const uint32_t planned = role == app ? (1u << 13) - 1 : role == bridge ? (1u | (1u << 13)) : 0;
    if (abi_planned && !abi) std::printf("not_executed step=abi\n");
    for (unsigned i = 0; i < 14; ++i) if ((planned & (1u << i)) && !(done & (1u << i)))
      std::printf("not_executed step=%s\n", steps[i]);
    for (unsigned i = 0; i < 14; ++i) if ((done & (1u << i)) && !(completed_steps & (1u << i)))
      std::printf("not_completed step=%s returned=%d\n", steps[i], (returned_steps & (1u << i)) ? 1 : 0);
    if (role != none && !closes) std::printf("not_executed step=owner_close\n");
  }
};
#endif
