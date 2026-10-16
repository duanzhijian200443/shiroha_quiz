#include "diagnostics/l1_e4_admission.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
using namespace shiroha_l1_crypto;
using namespace shiroha_l1_crypto::e4;
namespace {
unsigned assertions = 0;
void check(bool b, const char *s) {
  ++assertions;
  if (!b) {
    std::cerr << "FAIL: " << s << "\n";
    std::exit(1);
  }
}
GrantTarget target() {
  GrantTarget t;
  for (auto p :
       {&t.batch_id, &t.device_id, &t.compiler_id, &t.os_id, &t.stop_owner,
        &t.recovery_owner, &t.evidence_owner, &t.evidence_scope_id,
        &t.reviewer_id, &t.verifier_id, &t.user_approval_id})
    *p = "fake";
  for (auto p : {&t.account_identity_sha256, &t.exe_sha256,
                 &t.dependency_manifest_sha256, &t.toolchain_manifest_sha256,
                 &t.review_sha256, &t.verification_sha256})
    *p = std::string(64, '1');
  t.source_sha = t.base_sha = std::string(40, 'a');
  t.user_scope = "L1-CRYPTO";
  t.non_elevated = t.reviewer_approved = t.verifier_approved =
      t.evidence_output_approved = true;
  t.working_set_bytes = 1024;
  t.commit_bytes = 2048;
  t.handles = 10;
  t.window_start_ms = 1700000000000ULL;
  t.window_end_ms = t.window_start_ms + 120000;
  return t;
}
ClockReading clock_at(uint64_t delta = 0) {
  return {target().window_start_ms + delta, 500 + delta, 42, true};
}
BatchObjectPins pins() {
  BatchObjectPins p;
  unsigned i = 1;
  for (auto q : {&p.dir_pin, &p.receipt_pin, &p.grant_pin}) {
    q->volume_serial = 9;
    q->file_id[0] = uint8_t(i++);
  }
  return p;
}
ApprovalPromptModel make_prompt() {
  ApprovalPromptModel p;
  check(prompt(target(), L"FAKE-SID", p), "preapproval prompt");
  return p;
}
ApprovalUiResponse answer(const ApprovalPromptModel &p) {
  return {true, false, false, true, p.suffix, p.target_hash};
}
struct Store {
  std::mutex mutex;
  bool issued = false, requested = false;
  unsigned marker = 0, starts = 0;
  BatchObjectPins objects = pins();
  Journal bytes{};
  Receipt approval{};
};
struct Io final : GrantIo {
  Store &store;
  unsigned operation = 0, fail_at = 0;
  bool lost_reply = false;
  bool throw_failure = false;
  explicit Io(Store &s) : store(s) {}
  bool principal(const std::wstring &sid) override {
    return sid == L"FAKE-SID";
  }
  bool fails() {
    if (++operation != fail_at)
      return false;
    if (throw_failure)
      throw std::runtime_error("fixed_fake_failure");
    return true;
  }
  IoResult issue_new(const Receipt &r, BatchObjectPins &p) override {
    std::lock_guard<std::mutex> lock(store.mutex);
    if (store.issued)
      return IoResult::denied;
    store.issued = true;
    if (fails())
      return IoResult::unknown;
    store.approval = r;
    store.marker = 1;
    p = store.objects;
    return IoResult::ok;
  }
  bool inspect(const BatchObjectPins &p) override { return p == store.objects; }
  IoResult request_new(const Journal &j) override {
    std::lock_guard<std::mutex> lock(store.mutex);
    if (store.requested)
      return IoResult::denied;
    store.requested = true;
    if (fails())
      return IoResult::unknown;
    store.bytes = j;
    return IoResult::ok;
  }
  IoResult burn_issued() override {
    std::lock_guard<std::mutex> lock(store.mutex);
    if (!store.requested || store.marker != 1)
      return IoResult::denied;
    store.marker = 2;
    return fails() ? IoResult::unknown : IoResult::ok;
  }
  IoResult update_request(const Journal &j) override {
    if (fails())
      return IoResult::unknown;
    store.bytes = j;
    if (j[6] == 3)
      ++store.starts;
    return lost_reply ? IoResult::unknown : IoResult::ok;
  }
};
struct Worker final : WorkerPort {
  unsigned calls = 0;
  ClockReading current = clock_at(2);
  ClockReading read_clock() override { return current; }
  WorkerStart result{true, false, true, true, true, true,
                     true, true,  true, true, 123};
  WorkerStart start_suspended(const GrantTarget &, const Digest &,
                              ClockReading) override {
    ++calls;
    return result;
  }
};
void hashes_approval() {
  auto t = target();
  check(!t.user_approved && t.valid_pre_approval() && !t.valid(),
        "approval isn't fabricated for valid");
  auto p = make_prompt();
  auto unreviewed = t;
  unreviewed.reviewer_approved = false;
  auto validation = evaluate_pre_approval_target(unreviewed);
  check(validation.structure_complete && !validation.reviewer_verifier_ready &&
            !validation.valid_for_prompt(),
        "structure/review readiness are separate facts");
  std::string GrantTarget::*text_fields[] = {
      &GrantTarget::batch_id,
      &GrantTarget::device_id,
      &GrantTarget::account_identity_sha256,
      &GrantTarget::source_sha,
      &GrantTarget::base_sha,
      &GrantTarget::exe_sha256,
      &GrantTarget::dependency_manifest_sha256,
      &GrantTarget::compiler_id,
      &GrantTarget::os_id,
      &GrantTarget::toolchain_manifest_sha256,
      &GrantTarget::stop_owner,
      &GrantTarget::recovery_owner,
      &GrantTarget::evidence_owner,
      &GrantTarget::evidence_scope_id,
      &GrantTarget::reviewer_id,
      &GrantTarget::verifier_id,
      &GrantTarget::review_sha256,
      &GrantTarget::verification_sha256,
      &GrantTarget::user_approval_id,
      &GrantTarget::user_scope};
  for (auto field : text_fields) {
    auto drift = t;
    (drift.*field)[0] = (drift.*field)[0] == 'a' ? 'b' : 'a';
    std::string changed_hash;
    check(!compute_target_binding_sha256(drift, L"FAKE-SID", changed_hash) ||
              changed_hash != p.target_hash,
          "every textual target field bound");
  }
  auto a = answer(p);
  auto changed_prompt = p;
  changed_prompt.summary += "changed";
  check(!confirm(changed_prompt, a, t, L"FAKE-SID"),
        "display text cannot differ from consumed target");
  changed_prompt = p;
  changed_prompt.target.handles++;
  check(!confirm(changed_prompt, a, t, L"FAKE-SID"),
        "display model drift rejected even with unchanged digest field");
  for (auto label : {"Compiler=", "Evidence owner=", "Reviewer=", "Verifier=",
                     "SampledHandles="})
    check(p.summary.find(label) != std::string::npos,
          "mandatory labeled approval fields present");
  for (unsigned k = 0; k < 7; ++k) {
    auto r = a;
    auto changed = t;
    if (k == 0)
      r.cancelled = true;
    if (k == 1)
      r.timed_out = true;
    if (k == 2)
      r.checked = false;
    if (k == 3)
      r.suffix[0] = 'z';
    if (k == 4)
      r.displayed_hash[0] = 'z';
    if (k == 5)
      r.completed = false;
    if (k == 6)
      changed.handles++;
    check(!confirm(p, r, changed, L"FAKE-SID"),
          "cancel/timeout/input/drift rejected");
    Store s;
    Io io(s);
    GrantFlow g(io);
    check(!g.issue(p, r, changed, L"FAKE-SID", clock_at()) && !s.issued,
          "invalid approval has zero IO");
  }
  std::string h;
  t.user_approved = true;
  check(compute_target_binding_sha256(t, L"FAKE-SID", h) && h == p.target_hash,
        "approval result excluded from input hash");
  t.batch_id = "ab";
  t.device_id = "c";
  compute_target_binding_sha256(t, L"FAKE-SID", h);
  t.batch_id = "a";
  t.device_id = "bc";
  std::string other;
  compute_target_binding_sha256(t, L"FAKE-SID", other);
  check(h != other, "length framing prevents concatenation collision");
  auto ids = pins();
  check(compute_object_identity_sha256(p.target_hash, ids,
                                       t.account_identity_sha256, h),
        "post creation identity");
  for (unsigned i = 0; i < 3; ++i) {
    auto changed = ids;
    auto q = i == 0   ? &changed.dir_pin
             : i == 1 ? &changed.receipt_pin
                      : &changed.grant_pin;
    q->file_id = {};
    check(!compute_object_identity_sha256(p.target_hash, changed,
                                          t.account_identity_sha256, other),
          "missing File ID STOP");
    q->file_id[1] = 1;
    check(compute_object_identity_sha256(p.target_hash, changed,
                                         t.account_identity_sha256, other) &&
              h != other,
          "pin drift changes second hash");
  }
  ids.receipt_pin = ids.grant_pin;
  check(!ids.valid(), "duplicate identity rejected");
  Receipt r{};
  check(receipt(p, clock_at(), r) && valid_receipt(r, p, clock_at()),
        "receipt roundtrip");
  for (unsigned i = 0; i < 256; ++i) {
    auto bad = r;
    bad[i] ^= 1;
    check(!valid_receipt(bad, p, clock_at()), "receipt corruption rejected");
  }
  t = target();
  t.batch_id = std::string(80, 'b');
  ApprovalPromptModel long_p;
  check(prompt(t, L"FAKE-SID", long_p) && receipt(long_p, clock_at(), r) &&
            r[96] == 80,
        "full 80-byte Batch ID preserved");
  Journal j{};
  check(journal(JournalStage::requested, clock_at(), 0, p.target_hash, h, j) &&
            valid_journal(j),
        "128-byte journal");
  for (unsigned i = 0; i < 128; ++i) {
    auto bad = j;
    bad[i] ^= 1;
    check(!valid_journal(bad), "journal corruption rejected");
  }
}
void clocks_and_grants() {
  for (unsigned k = 0; k < 5; ++k) {
    ClockValidator v;
    auto r = clock_at();
    check(v.accept(r), "UTC much greater than mono accepted");
    r = clock_at(100);
    if (k == 0)
      --r.session;
    if (k == 1)
      r.utc = 1;
    if (k == 2)
      r.mono = 1;
    if (k == 3)
      r.utc += 1001;
    if (k == 4)
      r.valid = false;
    check(!v.accept(r) && !v.accept(clock_at(101)),
          "bad clock permanently stops");
  }
  auto p = make_prompt();
  auto r = answer(p);
  {
    Store delayed;
    Io port(delayed);
    GrantFlow flow(port);
    Worker worker;
    Controller c(flow, worker);
    check(flow.issue(p, r, target(), L"FAKE-SID", clock_at()) &&
              c.admit(clock_at(1), "fake"),
          "slow journal fixture admitted");
    worker.current = clock_at(90001);
    check(!c.start(clock_at(2)) && delayed.starts == 1 && !worker.calls &&
              delayed.marker == 2,
          "window rechecked after durable start reservation; no process after "
          "IO delay");
  }
  {
    Store lost;
    Io port(lost);
    GrantFlow flow(port);
    Worker worker;
    Controller c(flow, worker);
    check(flow.issue(p, r, target(), L"FAKE-SID", clock_at()),
          "lost reply fixture issued");
    port.lost_reply = true;
    check(!c.admit(clock_at(1), "fake") &&
              c.evidence().observation.verdict == OfflineVerdict::kUnknown &&
              lost.marker == 2 && flow.record().unknown && !worker.calls,
          "burned grant with lost receipt never launches");
    port.lost_reply = false;
    check(!c.admit(clock_at(2), "fake") && !c.start(clock_at(3)),
          "lost receipt never retries");
  }
  for (unsigned failure = 1; failure <= 10; ++failure) {
    Store s;
    Io io(s);
    io.fail_at = (failure - 1) % 5 + 1;
    io.throw_failure = failure > 5;
    GrantFlow g(io);
    Worker w;
    Controller c(g, w);
    const bool issued = g.issue(p, r, target(), L"FAKE-SID", clock_at());
    if (issued && c.admit(clock_at(1), "fake"))
      check(!c.start(clock_at(2)), "start journal failure blocks");
    check(w.calls == 0, "persistence failure never launches");
    Io restart(s);
    GrantFlow again(restart);
    check(!again.issue(p, r, target(), L"FAKE-SID", clock_at(3)),
          "reconstruction never reissues batch");
  }
  for (unsigned k = 0; k < 3; ++k) {
    auto t = target();
    if (k == 0)
      t.handles = 0;
    if (k == 1)
      t.commit_bytes = 0;
    if (k == 2)
      t.working_set_bytes = 0;
    ApprovalPromptModel invalid;
    check(!prompt(t, L"FAKE-SID", invalid), "unspecified real limits deny");
  }
  Store s;
  Io io(s);
  GrantFlow g(io);
  Worker w;
  Controller c(g, w);
  check(g.issue(p, r, target(), L"FAKE-SID", clock_at()) &&
            c.admit(clock_at(1), "fake") && c.start(clock_at(2)),
        "UTC/montonic integrated start");
  check(c.evidence().observation.launch_attempt_ms == 502 && w.calls == 1 &&
            !c.start(clock_at(3)),
        "single launch at mono origin");
  s.objects.grant_pin.file_id[0] ^= 1;
  c.settle(clock_at(3), true, true, false);
  check(c.state() == SupervisorState::kSettlementUnknown,
        "object drift before settlement unknown");
  for (unsigned repeat = 0; repeat < 64; ++repeat) {
    Store race;
    Io first(race), second(race);
    Journal j{};
    std::string object(64, '2');
    journal(JournalStage::requested, clock_at(), 0, p.target_hash, object, j);
    std::atomic<unsigned> ready{0}, winners{0};
    std::atomic<bool> go{false};
    auto compete = [&](Io &x) {
      ++ready;
      while (!go.load())
        std::this_thread::yield();
      if (x.request_new(j) == IoResult::ok)
        ++winners;
    };
    std::thread a(compete, std::ref(first)), b(compete, std::ref(second));
    while (ready != 2)
      std::this_thread::yield();
    go = true;
    a.join();
    b.join();
    check(winners == 1 && race.requested,
          "64 independent CREATE_NEW races one winner");
  }
}
void full_records(L1CryptoLedger &l, NativeObservation &n) {
  constexpr unsigned limits[] = {1, 3, 3, 6, 3, 45, 45};
  for (unsigned i = 0; i < 7; ++i)
    l.abi_calls[i] = {limits[i], limits[i], limits[i], limits[i], 0, 0};
  for (unsigned i = 0; i < 14; ++i)
    n.calls[i] = {kNativeLimits[i],
                  kNativeLimits[i],
                  kNativeLimits[i],
                  kNativeLimits[i],
                  0,
                  0};
  l.abi_attempted_total = 106;
  l.attempted = l.returned = l.completed = l.accepted = 16;
  l.successful = 12;
  l.buffers_allocated = l.releases_attempted = l.releases_succeeded = 45;
  l.samples = 18;
  n.acquired = n.released = 47;
}
void end_to_end_controller() {
  for (unsigned outcome = 0; outcome < 7; ++outcome) {
    Store store;
    Io io(store);
    GrantFlow grant(io);
    Worker worker;
    Controller c(grant, worker);
    auto p = make_prompt();
    check(grant.issue(p, answer(p), target(), L"FAKE-SID", clock_at()) &&
              c.admit(clock_at(1), "fake") && c.start(clock_at(2)),
          "complete pipeline launch");
    Digest d{};
    decode_hex_bytes(p.target_hash, d.data(), 32);
    check(!c.admit(clock_at(3), "fake-duplicate") &&
              c.state() == SupervisorState::kRunning,
          "duplicate admission neither consumes again nor rewrites live state");
    uint32_t seq = 1;
    auto hello = frame(Message::hello, seq++, 0, 1, d);
    put(hello.data() + 32, 123, 4);
    put(hello.data() + 36, 3, 4);
    Digest image{};
    decode_hex_bytes(target().exe_sha256, image.data(), 32);
    std::copy_n(image.begin(), 16, hello.begin() + 48);
    check(c.receive(hello, {}, clock_at(3)), "independent identity HELLO");
    for (uint16_t i = 0; i < 18; ++i) {
      auto f = frame(Message::sample, seq++, i, 18, d);
      put(f.data() + 32, 504 + i, 8);
      put(f.data() + 40, 512, 8);
      put(f.data() + 48, 1024, 8);
      put(f.data() + 56, 4, 4);
      put(f.data() + 60, i == 17 ? 16 : i, 4);
      check(c.receive(f, {504u + i, 512, 1024, 4, 0}, clock_at(4 + i)),
            "18 independent samples plus Worker samples");
    }
    L1CryptoLedger l;
    NativeObservation n;
    full_records(l, n);
    if (outcome == 2) {
      n.unknown = true;
      n.still_owned = 1;
    }
    Settlement bytes{};
    encode_settlement(l, n, bytes);
    auto frames = settlement_frames(bytes, d, seq);
    for (unsigned i = 0; i < (outcome == 1 ? 23u : 24u); ++i)
      check(c.receive(frames[i], {}, clock_at(30 + i)),
            "settlement frame accepted");
    c.settle(clock_at(outcome == 3 ? 30002 : 60), outcome != 4, outcome != 5,
             outcome != 6);
    check(c.evidence().observation.verdict ==
              (outcome == 0   ? OfflineVerdict::kPass
               : outcome == 5 ? OfflineVerdict::kFail
               : outcome == 3 ? OfflineVerdict::kFail
                              : OfflineVerdict::kUnknown),
          "only complete independent observations PASS");
    auto before = c.evidence();
    auto state = c.state();
    c.stop();
    c.receive(hello, {}, clock_at(100000));
    c.settle(clock_at(100001), true, true, true);
    check(c.state() == state &&
              c.evidence().observation.verdict == before.observation.verdict &&
              c.evidence().observation.process_end_ms ==
                  before.observation.process_end_ms &&
              c.evidence().logs_complete == before.logs_complete,
          "late events preserve terminal evidence");
  }
}
void settlement_and_stream() {
  L1CryptoLedger l;
  NativeObservation n;
  unsigned v = 256;
  for (auto p : scalars(l))
    *p = ++v;
  for (auto p : longs(l))
    *p = uint64_t(++v) << 33;
  for (auto c : {&l.abi_calls[0], &n.calls[0]})
    *c = {1000, 999, 998, 997, 996, 995};
  l.stopped = l.settlement_unknown = l.clock_initialized = true;
  l.first_failure = "buffer_release_unknown";
  l.failure_code = "SETTLEMENT_UNKNOWN";
  l.first_status = INT32_MIN;
  n.fail("native_budget", true);
  n.acquired = 47;
  n.released = 40;
  n.still_owned = 7;
  n.quarantined = 3;
  Settlement bytes{}, roundtrip{};
  check(encode_settlement(l, n, bytes), "all u32/u64 counts encoded");
  L1CryptoLedger decoded;
  NativeObservation dn;
  check(decode_settlement(bytes, decoded, dn) &&
            encode_settlement(decoded, dn, roundtrip) && bytes == roundtrip,
        "24-frame lossless encode/decode/compare");
  check(decoded.observation_failures == l.observation_failures &&
            decoded.first_status == INT32_MIN && dn.first_failure_unknown,
        "no u8 narrowing, status/UNKNOWN preserved");
  for (unsigned k = 0; k < 768; ++k) {
    auto bad = bytes;
    bad[k] ^= 1;
    check(!decode_settlement(bad, decoded, dn), "settlement digest corruption");
  }
  Digest d{};
  d[0] = 17;
  auto f = frame(Message::hello, 1, 0, 1, d);
  put(f.data() + 32, 123, 4);
  put(f.data() + 36, 3, 4);
  for (size_t chunk :
       {size_t(1), size_t(7), size_t(13), size_t(63), size_t(64)}) {
    size_t position = 0;
    Frame result{};
    auto read = [&](uint8_t *p, size_t cap) {
      auto len = (std::min)(chunk, cap);
      std::copy_n(f.begin() + position, len, p);
      position += len;
      return Chunk{len, false, false, false};
    };
    check(read_exact_frame(
              read, [] { return true; }, result) == ReadResult::frame &&
              result == f,
          "arbitrary fragmented pipe frame");
  }
  for (size_t end = 0; end < 64; ++end) {
    size_t pos = 0;
    Frame result{};
    auto read = [&](uint8_t *p, size_t cap) {
      if (pos == end)
        return Chunk{0, true, false, false};
      auto len = (std::min)(cap, end - pos);
      std::copy_n(f.begin() + pos, len, p);
      pos += len;
      return Chunk{len, false, false, false};
    };
    check(read_exact_frame(
              read, [] { return true; }, result) ==
              (end ? ReadResult::truncated : ReadResult::eof),
          "EOF and all 63 truncations");
  }
  Frame tmp{};
  check(read_exact_frame([](uint8_t *, size_t) { return Chunk{}; },
                         [] { return true; }, tmp) == ReadResult::error,
        "zero progress denied");
  check(read_exact_frame([](uint8_t *, size_t) { return Chunk{}; },
                         [] { return false; }, tmp) == ReadResult::timeout,
        "bounded read deadline");
  Admission a{500, 1024, 2048, 30000, 10};
  auto af = a.encode(d);
  Channel reverse(d, false);
  check(reverse.accept(af) && Admission::decode(af).handles == 10,
        "handle budget explicit; reverse seq starts at 1");
  a.handles = 0;
  Channel invalid(d, false);
  check(!invalid.accept(a.encode(d)), "missing handle ceiling rejected");
  // 24-part canonical order; test missing/reordered/duplicated/wrong binding.
  auto frames = settlement_frames(bytes, d, 3);
  for (int omit = -1; omit < 24; ++omit) {
    Channel channel(d, true);
    check(channel.accept(f), "hello accepted");
    auto stop = frame(Message::stop, 2, 0, 1, d);
    put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
    check(channel.accept(stop), "stop once");
    for (int i = 0; i < 24; ++i)
      if (i != omit)
        channel.accept(frames[size_t(i)]);
    check(channel.complete() == (omit == -1),
          "every missing settlement frame prevents complete");
    if (omit == -1)
      check(!channel.accept(frames[23]), "duplicate terminal frame denied");
  }
  Channel wrong(d, true);
  f[16] ^= 1;
  check(!wrong.accept(f), "target digest mismatch");
}
struct Steps final : LaunchSteps {
  unsigned kind, inspects = 0, resumes = 0, hellos = 0, dependency_checks = 0;
  explicit Steps(unsigned k) : kind(k) {}
  WorkerStart create() override {
    WorkerStart w;
    w.created = kind != 0;
    w.pid = 123;
    return w;
  }
  bool token() override {
    ++inspects;
    return kind != 1;
  }
  bool image() override {
    ++inspects;
    return kind != 2;
  }
  bool dependencies() override {
    ++inspects;
    ++dependency_checks;
    return kind != 3 && (kind != 9 || dependency_checks == 1);
  }
  bool handles() override {
    ++inspects;
    return kind != 4;
  }
  bool resume(bool &known) override {
    ++resumes;
    known = kind != 6;
    return kind != 5;
  }
  bool hello() override {
    ++hellos;
    return kind != 7;
  }
};
uint64_t fake_now = 0;
bool clock_fn(uint64_t &out) noexcept {
  out = fake_now;
  return true;
}
void worker_failures() {
  for (unsigned k = 0; k <= 9; ++k) {
    Steps steps(k);
    auto r = launch_once(steps);
    check(r.state() == (k == 0   ? WorkerState::kStartFailed
                        : k == 8 ? WorkerState::kRunning
                                 : WorkerState::kUnknown),
          "all created/noncreated failure windows");
    if (k < 5)
      check(!steps.resumes && !steps.hellos,
            "pre-resume mismatch never resumes");
    Store s;
    Io io(s);
    GrantFlow g(io);
    Worker w;
    w.result = r;
    Controller c(g, w);
    auto p = make_prompt();
    check(g.issue(p, answer(p), target(), L"FAKE-SID", clock_at()) &&
              c.admit(clock_at(1), "fake"),
          "failure fixture issued");
    check(c.start(clock_at(2)) == (k == 8),
          "only complete identity handshake runs");
    if (k && k != 8)
      check(c.evidence().custody_unsettled &&
                c.state() == SupervisorState::kSettlementUnknown,
            "created process retains UNKNOWN custody");
    if (k != 8) {
      auto state = c.state();
      auto before = c.evidence();
      c.stop();
      c.settle(clock_at(4), true, true, true);
      check(c.state() == state &&
                c.evidence().custody_unsettled == before.custody_unsettled &&
                c.evidence().observation.verdict == before.observation.verdict,
            "terminal outcome immutable");
    }
    Io reconstructed(s);
    GrantFlow replay(reconstructed);
    check(!replay.issue(p, answer(p), target(), L"FAKE-SID", clock_at(5)) &&
              s.starts == 1,
          "controller crash/rebuild after start never restores permission");
  }
  L1CryptoLedger ledger;
  Admission budget{500, 1024, 2048, 30000, 10};
  check(budget.bind(ledger), "bind launch origin once");
  ledger.clock_ms = clock_fn;
  fake_now = 30499;
  check(ledger.check_clock("before_work"), "29999ms admits");
  fake_now = 30500;
  check(!ledger.check_clock("before_work"),
        "delayed handshake cannot earn another 30s");
  NativeObservation n;
  n.check_admission = +[]() noexcept { return false; };
  unsigned calls = 0;
  check(!observe_native(
            NativeOp::kOpen, false, &n,
            [&] {
              ++calls;
              return true;
            },
            [](bool ok) { return ok; }, false) &&
            !calls,
        "direct native admission closes before call reservation");
  NativeObservationScope scope(n);
  NativeOwnerObservation owner;
  owner.acquire(true);
  n.fail("supervisor_stop");
  unsigned release = 0;
  check(owner.release(
            NativeOp::kClose,
            [&] {
              ++release;
              return true;
            },
            [](bool b) { return b; }, false) &&
            release == 1,
        "sole-owner release legal after STOP");
}
} // namespace
int main() {
  check(!kRealExecutionAuthorized, "real default denial");
  hashes_approval();
  clocks_and_grants();
  settlement_and_stream();
  worker_failures();
  end_to_end_controller();
  std::cout << "PASS: OFFLINE/FAKE E4 assertions=" << assertions
            << "; races=64; real Windows NOT RUN\n";
}
