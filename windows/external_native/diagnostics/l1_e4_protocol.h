#ifndef SHIROHA_L1_E4_PROTOCOL_H_
#define SHIROHA_L1_E4_PROTOCOL_H_
#include "diagnostics/l1_windows_admission.h"
#include <algorithm>
#include <limits>

namespace shiroha_l1_crypto {
namespace e4 {
using Digest = std::array<uint8_t, 32>;
inline void put(uint8_t *p, uint64_t n, size_t bytes) noexcept {
  for (size_t i = 0; i < bytes; ++i)
    p[i] = uint8_t(n >> (8 * i));
}
inline uint64_t get(const uint8_t *p, size_t bytes) noexcept {
  uint64_t n = 0;
  for (size_t i = 0; i < bytes; ++i)
    n |= uint64_t(p[i]) << (8 * i);
  return n;
}
inline Digest digest(const uint8_t *p, size_t n) noexcept {
  Digest d{};
  sha256_digest(p, n, d.data());
  return d;
}
inline bool zero(const uint8_t *p, size_t n) noexcept {
  for (size_t i = 0; i < n; ++i)
    if (p[i])
      return false;
  return true;
}
enum class Message : uint16_t {
  hello = 1,
  admission,
  sample,
  stop,
  settlement,
  ack
};
using Frame = std::array<uint8_t, 64>;
static_assert(sizeof(Frame) == 64, "wire size");
// Wire bytes SHL1; the corresponding LE integer is 0x314c4853, not 0x53484c31.
inline Frame frame(Message type, uint32_t seq, uint16_t part, uint16_t total,
                   const Digest &target) noexcept {
  Frame f{};
  put(f.data(), 0x314c4853u, 4);
  put(f.data() + 4, 1, 2);
  put(f.data() + 6, unsigned(type), 2);
  put(f.data() + 8, seq, 4);
  put(f.data() + 12, part, 2);
  put(f.data() + 14, total, 2);
  std::copy_n(target.begin(), 16, f.begin() + 16);
  return f;
}
struct Admission {
  uint64_t origin = 0, working = 0, commit = 0;
  uint32_t duration = 30000, handles = 0;
  bool valid() const noexcept {
    return duration == 30000 && working && commit && handles;
  }
  Frame encode(const Digest &d) const noexcept {
    auto f = frame(Message::admission, 1, 0, 1, d);
    auto p = f.data() + 32;
    put(p, origin, 8);
    put(p + 8, duration, 4);
    put(p + 12, handles, 4);
    put(p + 16, working, 8);
    put(p + 24, commit, 8);
    return f;
  }
  static Admission decode(const Frame &f) noexcept {
    auto p = f.data() + 32;
    Admission a;
    a.origin = get(p, 8);
    a.duration = uint32_t(get(p + 8, 4));
    a.handles = uint32_t(get(p + 12, 4));
    a.working = get(p + 16, 8);
    a.commit = get(p + 24, 8);
    return a;
  }
  bool bind(L1CryptoLedger &l) const noexcept {
    if (!valid() || l.clock_initialized || l.abi_attempted_total)
      return false;
    l.bind_launch_origin(origin);
    l.max_elapsed_ms = duration;
    l.working_set_limit_bytes = working;
    l.commit_limit_bytes = commit;
    l.handle_limit = handles;
    return true;
  }
};
enum class ReadResult { frame, eof, truncated, error, timeout };
struct Chunk {
  size_t bytes = 0;
  bool eof = false, error = false, timeout = false;
};
// Reader must itself be bounded/nonblocking. No synchronous OS read is called
// here.
template <class Reader, class Alive>
ReadResult read_exact_frame(Reader &&read, Alive &&alive, Frame &out) {
  Frame tmp{};
  size_t used = 0;
  for (unsigned calls = 0; calls < 64; ++calls) {
    if (!alive())
      return ReadResult::timeout;
    const auto c = read(tmp.data() + used, tmp.size() - used);
    if (!alive() || c.timeout)
      return ReadResult::timeout;
    if (c.error || c.bytes > tmp.size() - used || (c.eof && c.bytes))
      return ReadResult::error;
    if (c.eof)
      return used ? ReadResult::truncated : ReadResult::eof;
    if (!c.bytes)
      return ReadResult::error;
    used += c.bytes;
    if (used == 64) {
      out = tmp;
      return ReadResult::frame;
    }
  }
  return ReadResult::error;
}

// Enumerated safe source strings. An unrecognized diagnostic is a serialization
// failure, never silently replaced by "none" or serialized as arbitrary text.
inline const std::vector<const char *> &stages() {
  static const std::vector<const char *> s = [] {
    std::vector<const char *> v = {"none",
                                   "abi_call_budget_exceeded",
                                   "deadline_exceeded",
                                   "resource_observation_invalid",
                                   "resource_budget_exceeded",
                                   "resource_observation_failed",
                                   "call_budget_exceeded",
                                   "forbidden_symbol_resolution",
                                   "symbol_lookup_exception",
                                   "missing_allowed_symbol",
                                   "buffer_alloc_precondition",
                                   "buffer_alloc_exception",
                                   "buffer_alloc_null",
                                   "unknown_buffer_slot",
                                   "duplicate_buffer_release",
                                   "free_budget_unsettled",
                                   "buffer_release_unknown",
                                   "native_budget",
                                   "duplicate_or_unowned_release",
                                   "supervisor_stop",
                                   "before_work",
                                   "after_final_settlement"};
    for (auto name : L1CryptoLedger::kSteps)
      v.push_back(name);
    for (auto name : kNativeNames)
      v.push_back(name);
    return v;
  }();
  return s;
}
inline const std::array<const char *, 9> &codes() {
  static const std::array<const char *, 9> c = {"NONE",
                                                "BUDGET_EXCEEDED",
                                                "MEASUREMENT_UNAVAILABLE",
                                                "SETTLEMENT_UNKNOWN",
                                                "SECURITY_REJECT_MISMATCH",
                                                "ADMISSION_BLOCKED",
                                                "UNAUTHORIZED_ACCESS",
                                                "ARTIFACT_INVALID",
                                                "OWNERSHIP_UNKNOWN"};
  return c;
}
template <class List>
inline bool string_id(const List &list, const char *s, uint32_t &id) {
  if (!s)
    return false;
  for (size_t i = 0; i < list.size(); ++i)
    if (!std::strcmp(list[i], s)) {
      id = uint32_t(i);
      return true;
    }
  return false;
}
// 24x32=768: counts[21][6] u32 (504), ledger u32[32] (128),
// native u32[4] (16), ledger u64[8] (64), flags/status/stage IDs (20),
// zero padding (4), SHA256 of first 736 bytes (32). No narrowed counters.
using Settlement = std::array<uint8_t, 768>;
static_assert(kNativeOpCount == 14 && sizeof(unsigned) == 4,
              "frozen wire counter contract");
inline std::array<unsigned *, 32> scalars(L1CryptoLedger &l) noexcept {
  return {&l.attempted_steps,
          &l.returned_steps,
          &l.completed_steps,
          &l.attempted,
          &l.returned,
          &l.completed,
          &l.successful,
          &l.accepted,
          &l.abi_reserved,
          &l.generate_reserved,
          &l.encode_sign_reserved,
          &l.verify_reserved,
          &l.verify_positive_reserved,
          &l.verify_negative_reserved,
          &l.policy_reserved,
          &l.budget_rejections,
          &l.abi_attempted_total,
          &l.allowed_symbol_resolutions,
          &l.forbidden_symbol_attempts,
          &l.buffers_allocated,
          &l.buffers_live,
          &l.releases_attempted,
          &l.releases_succeeded,
          &l.releases_unknown,
          &l.duplicate_release_attempts,
          &l.observation_attempts,
          &l.observation_failures,
          &l.samples,
          &l.handles_first,
          &l.handles_last,
          &l.handles_max_sampled,
          &l.handle_limit};
}
inline std::array<uint64_t *, 8> longs(L1CryptoLedger &l) noexcept {
  return {&l.peak_working_set,
          &l.peak_commit,
          &l.working_set_limit_bytes,
          &l.commit_limit_bytes,
          &l.max_elapsed_ms,
          &l.start_ms,
          &l.last_ms,
          &l.elapsed_ms};
}
inline bool encode_settlement(const L1CryptoLedger &source,
                              const NativeObservation &native,
                              Settlement &out) {
  L1CryptoLedger l = source;
  Settlement b{};
  size_t at = 0;
  auto u32 = [&](uint32_t v) {
    put(b.data() + at, v, 4);
    at += 4;
  };
  auto counts = [&](const CallCounts &c) {
    for (auto v : {c.attempted, c.returned, c.accepted, c.settled, c.unknown,
                   c.returned_failure})
      u32(v);
  };
  for (auto c : l.abi_calls)
    counts(c);
  for (auto c : native.calls)
    counts(c);
  for (auto p : scalars(l))
    u32(*p);
  for (auto v : {native.acquired, native.released, native.still_owned,
                 native.quarantined})
    u32(v);
  for (auto p : longs(l)) {
    put(b.data() + at, *p, 8);
    at += 8;
  }
  u32(unsigned(l.clock_initialized) | (unsigned(l.stopped) << 1) |
      (unsigned(l.settlement_unknown) << 2) | (unsigned(native.stopped) << 3) |
      (unsigned(native.unknown) << 4) |
      (unsigned(native.first_failure_unknown) << 5));
  u32(uint32_t(l.first_status));
  uint32_t id = 0;
  if (!string_id(codes(), l.failure_code, id))
    return false;
  u32(id);
  if (!string_id(stages(), l.first_failure, id))
    return false;
  u32(id);
  if (!string_id(stages(), native.first_failure, id))
    return false;
  u32(id);
  if (at != 732)
    return false;
  auto d = digest(b.data(), 736);
  std::copy(d.begin(), d.end(), b.begin() + 736);
  out = b;
  return true;
}
inline bool decode_settlement(const Settlement &b, L1CryptoLedger &out,
                              NativeObservation &obs) {
  auto d = digest(b.data(), 736);
  if (!std::equal(d.begin(), d.end(), b.begin() + 736) ||
      !zero(b.data() + 732, 4))
    return false;
  L1CryptoLedger l;
  NativeObservation n;
  size_t at = 0;
  auto u32 = [&]() {
    auto v = uint32_t(get(b.data() + at, 4));
    at += 4;
    return v;
  };
  auto counts = [&](CallCounts &c) {
    c.attempted = u32();
    c.returned = u32();
    c.accepted = u32();
    c.settled = u32();
    c.unknown = u32();
    c.returned_failure = u32();
  };
  for (auto &c : l.abi_calls)
    counts(c);
  for (auto &c : n.calls)
    counts(c);
  for (auto p : scalars(l))
    *p = u32();
  n.acquired = u32();
  n.released = u32();
  n.still_owned = u32();
  n.quarantined = u32();
  for (auto p : longs(l)) {
    *p = get(b.data() + at, 8);
    at += 8;
  }
  auto flags = u32();
  if (flags & ~63u)
    return false;
  l.clock_initialized = (flags & 1) != 0;
  l.stopped = (flags & 2) != 0;
  l.settlement_unknown = (flags & 4) != 0;
  n.stopped = (flags & 8) != 0;
  n.unknown = (flags & 16) != 0;
  n.first_failure_unknown = (flags & 32) != 0;
  auto status = u32();
  int64_t signed_status =
      status <= INT32_MAX ? int64_t(status) : int64_t(status) - 4294967296LL;
  l.first_status = int(signed_status);
  auto code = u32(), ls = u32(), ns = u32();
  if (code >= codes().size() || ls >= stages().size() || ns >= stages().size())
    return false;
  l.failure_code = codes()[code];
  l.first_failure = stages()[ls];
  n.first_failure = stages()[ns];
  out = l;
  obs = n;
  return true;
}
inline std::array<Frame, 24> settlement_frames(const Settlement &s,
                                               const Digest &d, uint32_t seq) {
  std::array<Frame, 24> frames{};
  for (uint16_t i = 0; i < 24; ++i) {
    frames[i] = frame(Message::settlement, seq + i, i, 24, d);
    std::copy_n(s.begin() + 32 * i, 32, frames[i].begin() + 32);
  }
  return frames;
}
// Single directional parser owns sequence, order, capacity and partial
// settlement. A second parser must be used for the reverse direction.
class Channel {
public:
  Channel(Digest target, bool from_worker, bool admission_only = false)
      : target_(target), worker_(from_worker),
        admission_only_(admission_only) {}
  bool accept(const Frame &f) {
    if (failed_ || count_ >= (worker_ ? 44u : 3u))
      return fail();
    if (get(f.data(), 4) != 0x314c4853u || get(f.data() + 4, 2) != 1 ||
        get(f.data() + 8, 4) != count_ + 1 ||
        !std::equal(target_.begin(), target_.begin() + 16, f.begin() + 16))
      return fail();
    auto type = get(f.data() + 6, 2), part = get(f.data() + 12, 2),
         total = get(f.data() + 14, 2);
    auto p = f.data() + 32;
    if (type < 1 || type > 6)
      return fail();
    if (type == unsigned(Message::stop)) {
      if (stopped_ || acknowledged_ || !count_ || total != 1 || part ||
          get(p, 4) < 1 || get(p, 4) > unsigned(StopReason::kSettlement) ||
          !zero(p + 16, 16))
        return fail();
      stopped_ = true;
    } else if (worker_) {
      if (!count_) {
        if (type != 1 || part || total != 1 || !get(p, 4) ||
            get(p + 4, 4) != 3 || get(p + 8, 4) || !zero(p + 12, 4))
          return fail();
      } else if (type == 3) {
        const auto expected_completed =
            admission_only_ ? 0u : (samples_ == 17 ? 16u : samples_);
        if (stopped_ || parts_ || samples_ >= 18 || total != 18 ||
            part != samples_ || get(p + 28, 4) != expected_completed)
          return fail();
        ++samples_;
      } else if (type == 5) {
        if (total != 24 || part != parts_ || parts_ >= 24 ||
            (samples_ != 18 && !stopped_))
          return fail();
        std::copy_n(p, 32, settlement_.begin() + 32 * parts_);
        ++parts_;
        if (parts_ == 24) {
          L1CryptoLedger l;
          NativeObservation n;
          if (!decode_settlement(settlement_, l, n))
            return fail();
        }
      } else
        return fail();
    } else {
      if (!count_) {
        if (type != 2 || part || total != 1 || !Admission::decode(f).valid())
          return fail();
      } else {
        if (type != 6 || acknowledged_ || part || total != 1 ||
            get(p, 4) != 1 || !zero(p + 4, 28))
          return fail();
        acknowledged_ = true;
      }
    }
    ++count_;
    return true;
  }
  bool complete() const noexcept { return worker_ && !failed_ && parts_ == 24; }
  bool records(L1CryptoLedger &l, NativeObservation &n) const {
    return complete() && decode_settlement(settlement_, l, n);
  }
  bool healthy() const noexcept { return !failed_; }
  bool stopped() const noexcept { return stopped_; }
  unsigned sample_count() const noexcept { return samples_; }
  unsigned frames() const noexcept { return count_; }
  void broken() noexcept { failed_ = true; }

private:
  bool fail() noexcept {
    failed_ = true;
    return false;
  }
  Digest target_;
  bool worker_, admission_only_ = false, failed_ = false, stopped_ = false,
                acknowledged_ = false;
  unsigned count_ = 0, samples_ = 0, parts_ = 0;
  Settlement settlement_{};
};
} // namespace e4
} // namespace shiroha_l1_crypto
#endif
