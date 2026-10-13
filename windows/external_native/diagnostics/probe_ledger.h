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
  uint32_t done = 0;
  unsigned abi = 0, acquires = 0, protects = 0, begins = 0, commits = 0, aborts = 0, closes = 0;
  bool stopped = false;
  bool (*sample)(ProbeLedger&) noexcept = nullptr;
  uint64_t peak_working_set = 0, peak_commit = 0;
  uint32_t handles_first = 0, handles_last = 0, handles_max_sampled = 0, samples = 0;
  explicit ProbeLedger(Role value) noexcept : role(value) {}
  void stop(const char* step, int status) noexcept {
    if (!stopped) std::printf("STOP step=%s status=%d\n", step, status);
    stopped = true;
  }
  bool resources(uint64_t working, uint64_t commit, uint32_t handles) noexcept {
    peak_working_set = working; peak_commit = commit;
    if (samples++ == 0) handles_first = handles;
    handles_last = handles;
    if (handles > handles_max_sampled) handles_max_sampled = handles;
    // Candidate ceilings must be included explicitly in any future batch grant.
    return working <= 64ull * 1024 * 1024 && commit <= 64ull * 1024 * 1024 && handles <= 128;
  }
  bool observe() noexcept {
    if (sample && !sample(*this)) stop("resource_observation_or_budget", -1);
    return !stopped;
  }
  bool record(const char* step, int status, int expected, bool valid) noexcept {
    if (std::strcmp(step, "abi") == 0) ++abi;
    else {
      for (unsigned i = 0; i < 14; ++i) if (std::strcmp(step, steps[i]) == 0) done |= 1u << i;
      if (std::strcmp(step, "acquire") == 0) ++acquires;
      else if (std::strncmp(step, "protect", 7) == 0) ++protects;
      else if (std::strncmp(step, "begin", 5) == 0 || std::strcmp(step, "bridge_begin") == 0) ++begins;
      else if (std::strncmp(step, "abort", 5) == 0) ++aborts;
      else ++commits;
    }
    if (status != expected || !valid) stop(step, status);
    return observe();
  }
  bool release(int status) noexcept {
    ++closes;
    std::printf("cleanup owner_close=%d\n", status);
    if (status != 0) stop("owner_close", status);
    return observe();
  }
  ~ProbeLedger() noexcept {
    std::printf("counts abi=%u acquire=%u protect=%u app_begin=%u bridge_begin=%u commit=%u abort=%u close=%u\n",
        abi, acquires, protects, role == app ? begins : 0, role == bridge ? begins : 0, commits, aborts, closes);
    std::printf("resources samples=%u peak_working_set=%llu peak_commit=%llu handles_first=%u handles_last=%u handles_max_sampled=%u\n",
        samples, static_cast<unsigned long long>(peak_working_set), static_cast<unsigned long long>(peak_commit),
        handles_first, handles_last, handles_max_sampled);
    const uint32_t planned = role == app ? (1u << 13) - 1 : role == bridge ? (1u | (1u << 13)) : 0;
    for (unsigned i = 0; i < 14; ++i) if ((planned & (1u << i)) && !(done & (1u << i)))
      std::printf("not_executed step=%s\n", steps[i]);
    if (role != none && !closes) std::printf("not_executed step=owner_close\n");
  }
};
#endif
