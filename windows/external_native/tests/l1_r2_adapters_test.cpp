#include "diagnostics/l1_r2_adapters.h"
#include "tests/l1_r1_fixture.h"

namespace z = shiroha_l1_crypto::r2;
namespace {
z::Limits limits(const r::Frozen &f) {
  z::Limits l;
  l.custodian_sha256 = std::string(64, '7');
  l.channel_sha256 = std::string(64, '8');
  l.process[0] = {f.target.scope.controller_working,
                  f.target.scope.controller_commit,
                  f.target.scope.controller_handles};
  l.process[1] = {3072, 6144, 16};
  l.process[2] = {f.target.grant.working_set_bytes,
                  f.target.grant.commit_bytes,
                  f.target.grant.handles};
  l.polls = f.manifest.max_pumps;
  l.poll_ms = 10;
  l.ui_events = 64;
  l.approval_ms = 30000;
  l.handoff_ms = 15000;
  return l;
}
r::Frozen r2_frozen() {
  auto f = frozen();
  auto l = limits(f);
  f.manifest.pins[0].bytes_sha256 = f.manifest.build.controller;
  f.manifest.pins[1].bytes_sha256 = l.custodian_sha256;
  f.manifest.pins[2].bytes_sha256 = f.manifest.build.worker;
  f.manifest.r2_sha256 = l.hash();
  f.target.scope.wiring_manifest_sha256 = f.manifest.hash();
  f.target.grant.evidence_scope_id = f.target.scope.hash();
  check(f.valid() && l.valid(), "valid R2 frozen target and limits");
  return f;
}
struct Disk final : z::PersistencePort {
  std::vector<std::vector<uint8_t>> records;
  uint32_t fail_write = 0, fail_flush = 0, short_write = 0, inspect_fail = 0;
  uint32_t inspections = 0;
  bool unknown = false;
  r::Origin origin() const noexcept override { return r::Origin::kFake; }
  bool inspect_destination() override {
    return ++inspections != inspect_fail;
  }
  z::WriteStatus write(const uint8_t *b, size_t n, size_t &done) override {
    const auto index = uint32_t(records.size() + 1);
    if (index == short_write) {
      done = n - 1;
      return z::WriteStatus::ok;
    }
    if (index == fail_write) {
      done = 0;
      return unknown ? z::WriteStatus::unknown : z::WriteStatus::denied;
    }
    done = n;
    records.emplace_back(b, b + n);
    return z::WriteStatus::ok;
  }
  z::WriteStatus flush() override {
    if (records.size() == fail_flush)
      return unknown ? z::WriteStatus::unknown : z::WriteStatus::denied;
    return z::WriteStatus::ok;
  }
};
struct Proof final : z::ProofPort {
  Io &io;
  const r::Frozen &f;
  unsigned calls = 0;
  bool unconsumed = false, wrong_stage = false, unpinned = false;
  bool bad_chronology = false;
  Proof(Io &i, const r::Frozen &v) : io(i), f(v) {}
  bool read_once(z::Consumption &out) override {
    if (++calls > 1 || !io.issued || !io.requested)
      return false;
    out.receipt = io.saved_receipt;
    out.journal = io.journal;
    if (wrong_stage)
      out.journal[6] = 2;
    out.marker = unconsumed ? 1 : 2;
    uint8_t idx = 1;
    for (auto q : {&out.pins.dir_pin, &out.pins.receipt_pin, &out.pins.grant_pin}) {
      q->volume_serial = 9;
      q->file_id[0] = idx++;
    }
    out.issued = {x::get(out.receipt.data() + 8, 8),
                  x::get(out.receipt.data() + 16, 8),
                  x::get(out.receipt.data() + 24, 8), true};
    const uint64_t launch_utc = x::get(out.journal.data() + 16, 8);
    const uint64_t launch_mono = x::get(out.journal.data() + 24, 8);
    out.now = {bad_chronology ? launch_utc - 1 : launch_utc,
               bad_chronology ? launch_mono - 1 : launch_mono,
               out.issued.session, true};
    out.independently_pinned = !unpinned;
    return true;
  }
};
struct Owner final : z::OwnerPort {
  Creator base;
  std::array<ResourceSample, 3> samples{{
      {500, 1024, 2048, 4, 0},
      {500, 1536, 3072, 6, 0},
      {500, 2048, 4096, 8, 0}}};
  bool sample_fail = false, measure_throw = false;
  std::array<z::ImageObservation, 3> images{};
  unsigned measurements = 0, accepts = 0;
  Owner(const r::Frozen &v, Io &i) : base(v, i) {
    for (size_t n = 0; n < 3; ++n) {
      images[n] = {r::Origin::kFake, r::IoStatus::kOk, true,
                   v.manifest.pins[n].object, v.manifest.pins[n].bytes_sha256,
                   v.manifest.pins[n].security_sha256};
    }
  }
  std::array<z::ImageObservation, 3> measure_hosts() override {
    ++measurements;
    if (measure_throw)
      throw 1; // injected I/O failure; no OS operations
    auto hosts = images;
    hosts[2] = {}; // Worker does not exist before accept/create
    return hosts;
  }
  r::CustodyReceipt accept_intent(const r::Frozen &v) override {
    ++accepts;
    return base.accept_intent(v);
  }
  x::WorkerStart create() override { return base.create(); }
  r::ProcessIdentity process_identity() override {
    return base.process_identity();
  }
  r::CustodyReceipt acknowledge_identity(const r::ProcessIdentity &p) override {
    return base.acknowledge_identity(p);
  }
  void controller_lost() noexcept override { base.controller_lost(); }
  bool token() override { return base.token(); }
  bool image() override { return base.image(); }
  bool dependencies() override { return base.dependencies(); }
  bool handles() override { return base.handles(); }
  bool resume(bool &k) override { return base.resume(k); }
  bool hello() override { return base.hello(); }
  bool approve(const x::ApprovalPromptModel &p,
               x::ApprovalUiResponse &r) override {
    return base.approve(p, r);
  }
  x::ClockReading read_clock() override { return base.read_clock(); }
  y::Observation observe() override { return base.observe(); }
  bool next(x::Frame &f, bool &a) override { return base.next(f, a); }
  bool send(const x::Frame &f) override { return base.send(f); }
  bool close_observed_exit() override { return base.close_observed_exit(); }
  bool close_owned_io() override { return base.close_owned_io(); }
  bool sample_three(std::array<ResourceSample, 3> &out) override {
    if (sample_fail)
      return false;
    out = samples;
    return true;
  }
};
struct ControlWire final : z::ControlPort {
  z::Endpoint &endpoint;
  bool peer_ok = true, drop_reply = false, corrupt_reply = false;
  bool wrong_batch_reply = false, wrong_target_reply = false;
  uint32_t drop_on_call = 0, calls = 0;
  explicit ControlWire(z::Endpoint &e) : endpoint(e) {}
  bool peer_checked() override { return peer_ok; }
  bool exchange(const z::Packet &in, z::Packet &out) override {
    ++calls;
    if (drop_reply || (drop_on_call && calls == drop_on_call))
      return false;
    if (!endpoint.dispatch(in, out))
      return false;
    if (corrupt_reply)
      out[480] ^= 1;
    if (wrong_target_reply)
      out[16] ^= 1;
    if (wrong_batch_reply)
      out[48] ^= 1;
    return true;
  }
};
struct R2Fixture {
  r::Frozen f = r2_frozen();
  z::Limits lim = limits(f);
  Io io;
  Id id{f};
  Owner owner{f, io};
  Proof proof{io, f};
  Disk custody_disk, evidence_disk;
  z::CustodyJournal journal{custody_disk, f.target.grant.batch_id, f.hash(),
                            f.manifest.custody_owner};
  z::Custodian custodian{f, lim, owner, proof, journal};
  z::Endpoint endpoint{f, lim.channel_sha256, custodian};
  ControlWire wire{endpoint};
  z::Proxy proxy{f, lim.channel_sha256, wire, owner};
  z::PersistentEvidence sink{evidence_disk, f.target.grant.batch_id, f.hash(),
                             f.manifest.evidence_owner,
                             lim.polls + 32};
  r::Composition c{f, io, id, proxy, sink};
  void finish() {
    for (unsigned i = 0; i < 140 && c.pump(); ++i) {
    }
  }
};
unsigned last_journal_state(const R2Fixture &t) {
  return t.custody_disk.records.empty()
             ? 999u
             : unsigned(x::get(t.custody_disk.records.back().data() + 12, 4));
}

void test_three_process_closed_loop() {
  R2Fixture t;
  ControllerBoot boot(t.c);
  wchar_t name[] = L"controller";
  wchar_t *argv[] = {name};
  check(r::controller_process_entry(1, argv, boot) == 0,
        "three-process Controller->Proxy->Endpoint->Custodian->Worker closed loop");
  const auto v = t.c.result();
  check(v.terminal && v.evidence_preserved &&
            v.last.security == OfflineVerdict::kPass &&
            v.last.stability == OfflineVerdict::kNotRun,
        "R2 security PASS remains distinct from unrun OS stability");
  check(t.custodian.state() == z::State::released && !t.custodian.retained(),
        "Custodian reaches released state after observed exit and IO close");
  check(t.owner.measurements == 1,
        "Batch acceptance uses one Owner host snapshot in the Fake flow");
  check(t.owner.base.creates == 1 && t.owner.base.resumes == 1 &&
            t.owner.base.close_calls == 1 && t.proof.calls == 1,
        "exactly one consumption proof, create, Resume and observed close");
  check(t.journal.count() == 12 && !t.journal.failed() &&
            t.custody_disk.records.size() == 12,
        "all 12 custody transitions persisted and flushed in order");
  check(t.sink.writes() == t.evidence_disk.records.size() &&
            t.sink.flushes() == t.evidence_disk.records.size() &&
            !t.sink.failed(),
        "every evidence record written and flushed once");
  const auto &peaks = t.custodian.peaks();
  check(peaks[0].peak_working_set == 1024 && peaks[1].peak_working_set == 1536 &&
            peaks[2].peak_working_set == 2048,
        "Controller, Custodian and Worker peaks accounted separately");

  // Reconstructed Controller cannot replay against the same Custodian or Proof.
  Disk second_evidence;
  z::PersistentEvidence second_sink{second_evidence, t.f.target.grant.batch_id,
                                    t.f.hash(), t.f.manifest.evidence_owner,
                                    t.lim.polls + 32};
  r::Composition replay(t.f, t.io, t.id, t.proxy, second_sink);
  check(!replay.begin() && t.owner.base.creates == 1 &&
            t.owner.base.resumes == 1,
        "recovered/reconstructed Controller cannot consume or create twice");
}

void test_custody_lifecycle_and_crashes() {
  // Direct create without accept_intent is rejected.
  {
    R2Fixture t;
    auto s = t.custodian.create();
    check(!s.created && t.custodian.state() == z::State::unknown &&
              t.owner.base.creates == 0,
          "Custodian refuses create before accepting batch custody");
  }
  // Unconsumed grant or stage != start prevents create.
  for (int mode = 0; mode < 4; ++mode) {
    R2Fixture t;
    t.proof.unconsumed = (mode == 0);
    t.proof.wrong_stage = (mode == 1);
    t.proof.unpinned = (mode == 2);
    t.proof.bad_chronology = (mode == 3);
    check(!t.c.begin() && t.owner.base.creates == 0 &&
              t.custodian.state() == z::State::unknown,
          "consumption proof failure stops before Worker creation");
  }
  // Controller crash after create retains Custodian ownership and records UNKNOWN.
  {
    R2Fixture t;
    check(t.c.begin(), "start before controller crash");
    const auto before = t.journal.count();
    t.c.controller_lost();
    check(t.custodian.state() == z::State::unknown && t.custodian.retained() &&
              t.owner.base.owner_handles && t.owner.base.close_calls == 0 &&
              t.journal.count() == before + 1,
          "Controller crash transitions Custodian to UNKNOWN while retaining handles");
    // Custodian can still preserve its own獨立 evidence stream on Controller loss.
    Disk custodian_disk;
    z::PersistentEvidence custodian_sink{
        custodian_disk, t.f.target.grant.batch_id, t.f.hash(),
        t.f.manifest.evidence_owner, 16};
    r::Record rec = t.c.result().last;
    rec.sequence = 1;
    rec.previous.clear();
    rec.stage = r::Stage::kRecoveryRequired;
    rec.recovery_required = true;
    auto ack = custodian_sink.preserve(rec);
    check(ack.status == r::IoStatus::kOk && custodian_disk.records.size() == 1,
          "Custodian independently preserves recovery evidence on Controller crash");
  }
  // Custodian crash / loss at every critical stage yields UNKNOWN and never PASS.
  for (uint32_t drop_call = 1; drop_call <= 10; ++drop_call) {
    R2Fixture t;
    t.wire.drop_on_call = drop_call;
    if (t.c.begin())
      t.finish();
    check(t.c.result().last.security != OfflineVerdict::kPass &&
              t.owner.base.creates <= 1 && t.owner.base.resumes <= 1,
          "control channel/Custodian loss at any step fails closed without retry");
  }
  // Custody journal write/flush failures at every transition.
  for (uint32_t fail_idx = 1; fail_idx <= 12; ++fail_idx) {
    R2Fixture t;
    t.custody_disk.fail_write = fail_idx;
    if (t.c.begin())
      t.finish();
    check(t.c.result().last.security != OfflineVerdict::kPass &&
              t.custodian.state() == z::State::unknown,
          "custody journal write failure enters UNKNOWN and denies PASS");
  }
  // Wrong peer/batch/target/corrupt control packet rejected.
  for (int k = 0; k < 4; ++k) {
    R2Fixture t;
    t.wire.peer_ok = (k != 0);
    t.wire.corrupt_reply = (k == 1);
    t.wire.wrong_target_reply = (k == 2);
    t.wire.wrong_batch_reply = (k == 3);
    check(!t.c.begin() && t.c.result().last.security != OfflineVerdict::kPass,
          "invalid control peer or packet binding rejected");
  }
  // Created identity mismatch prevents Resume.
  {
    R2Fixture t;
    t.owner.base.wrong_process = true;
    check(!t.c.begin() && t.owner.base.creates == 1 &&
              t.owner.base.resumes == 0 && t.owner.base.owner_handles,
          "identity mismatch after create blocks Resume and retains handles");
  }
  // Worker not exited cannot close or PASS.
  {
    R2Fixture t;
    t.owner.base.no_exit = true;
    check(t.c.begin(), "start no-exit fixture");
    t.finish();
    check(t.c.result().last.security != OfflineVerdict::kPass &&
              t.owner.base.close_calls == 0 && t.custodian.retained(),
          "unexited Worker never closed or declared PASS");
  }
}

void test_evidence_and_resource_budgets() {
  // Evidence write failure, partial write, flush failure, destination inspect failure.
  for (int mode = 0; mode < 4; ++mode) {
    R2Fixture t;
    if (mode == 0)
      t.evidence_disk.fail_write = 3;
    if (mode == 1)
      t.evidence_disk.short_write = 3;
    if (mode == 2)
      t.evidence_disk.fail_flush = 3;
    if (mode == 3)
      t.evidence_disk.inspect_fail = 5;
    if (t.c.begin())
      t.finish();
    check(!t.c.result().evidence_preserved &&
              t.c.result().last.security != OfflineVerdict::kPass &&
              t.sink.failed(),
          "evidence write/short-write/flush/inspect failure burns stream and denies PASS");
  }
  // Nine resource limits across three processes: exceeding any of the 9 fails closed.
  for (size_t proc = 0; proc < 3; ++proc) {
    for (int field = 0; field < 3; ++field) {
      R2Fixture t;
      if (field == 0)
        t.owner.samples[proc].peak_working_set =
            t.lim.process[proc].working + 1;
      if (field == 1)
        t.owner.samples[proc].peak_commit = t.lim.process[proc].commit + 1;
      if (field == 2)
        t.owner.samples[proc].handles = t.lim.process[proc].handles + 1;
      if (t.c.begin())
        t.finish();
      check(t.c.result().last.security != OfflineVerdict::kPass &&
                t.custodian.state() == z::State::unknown,
            "exceeding any of the 9 three-process resource ceilings rejects");
    }
  }
  // Bounded artifact reader: short read, oversize, size change after read.
  struct FakeReader final : z::ReadPort {
    std::vector<uint8_t> data;
    bool short_chunk = false, mutate_size = false;
    bool size_called = false;
    bool size(uint64_t &n) override {
      n = data.size() + (mutate_size && size_called ? 1 : 0);
      size_called = true;
      return true;
    }
    bool rewind() override { return true; }
    bool read(uint8_t *p, size_t req, size_t &ret) override {
      ret = short_chunk ? req - 1 : req;
      std::memcpy(p, data.data(), ret);
      return true;
    }
  };
  {
    FakeReader r;
    r.data.assign(131072, 0x42);
    std::string h;
    uint32_t reads = 0;
    check(z::bounded_hash(r, h, reads) && reads == 2 && h.size() == 64,
          "bounded_hash reads exact 64KiB blocks");
    r.short_chunk = true;
    r.size_called = false;
    check(!z::bounded_hash(r, h, reads) && reads == 1,
          "short artifact read stops immediately on first block");
    r.short_chunk = false;
    r.mutate_size = true;
    r.size_called = false;
    check(!z::bounded_hash(r, h, reads),
          "post-read artifact size drift rejected");
    r.data.assign(z::kArtifactBytes + 1, 0);
    r.mutate_size = false;
    r.size_called = false;
    check(!z::bounded_hash(r, h, reads) && reads == 0,
          "oversize artifact rejected before ReadFile");
  }
  // PollBudget and UiBudget hard ceilings.
  {
    z::PollBudget pb{4, 0, 0, 0, false};
    for (int i = 0; i < 4; ++i)
      check(pb.poll(), "polls within budget");
    check(!pb.poll() && pb.failed, "5th poll exceeds limit");
    z::PollBudget rb{4, 0, 0, 0, false};
    check(rb.read(64, 32, false), "positive partial frame read allowed");
    check(!rb.read(64, 0, true) && rb.failed, "EOF read rejected");
    z::PollBudget wb{4, 0, 0, 0, false};
    check(!wb.write(64, 32, 3) && wb.failed, "short pipe write rejected");

    z::UiBudget ub{1000, 5000, 1000, 3, 0, false};
    check(ub.event(1100) && ub.event(1200) && ub.event(1300),
          "UI events within limit");
    check(!ub.event(1400) && ub.failed, "UI event over limit rejected");
    z::UiBudget tb{1000, 5000, 1000, 10, 0, false};
    check(!tb.event(6000) && tb.failed, "UI event at deadline rejected");
  }
  // Default denial on Custodian process entry.
  {
    wchar_t a[] = L"custodian", b[] = L"extra";
    wchar_t *one[] = {a}, *two[] = {a, b};
    check(!z::allow_live_execution() &&
              z::custodian_process_entry(1, one) == 10 &&
              z::custodian_process_entry(2, two) == 64,
          "custodian entry unconditionally denies live execution and bad args");
  }
}
void test_state_gates_and_unknown_evidence() {
  // Every Owner operation is rejected before its lifecycle state, without
  // touching the Owner or the journal.
  {
    R2Fixture t;
    x::Frame f{};
    bool available = false;
    check(!t.custodian.dependencies() && !t.custodian.next(f, available) &&
              !t.custodian.send(f) && !t.custodian.observe().healthy &&
              !t.custodian.close_observed_exit() &&
              !t.custodian.close_owned_io(),
          "Custodian rejects owner operations outside their lifecycle state");
    check(t.custodian.state() == z::State::preapproved &&
              t.owner.base.io_closes == 0 && t.journal.count() == 0,
          "out-of-order operations do not touch Owner, journal or state");
    t.custodian.controller_lost();
    check(t.custodian.state() == z::State::unknown &&
              t.journal.count() == 1 &&
              last_journal_state(t) == unsigned(z::State::unknown),
          "controller loss records exactly one UNKNOWN journal entry");
  }
  // A normal pre-create measurement failure after acceptance must retain
  // custody and journal UNKNOWN, never a premature released record.
  {
    R2Fixture t;
    t.id.drift_at = 4; // start_suspended::inspect_target, before create attempt
    check(!t.c.begin() && t.owner.base.creates == 0 &&
              t.owner.base.io_closes == 0,
          "pre-create identity drift never reaches create or close_owned_io");
    check(t.custodian.state() == z::State::unknown && t.custodian.retained() &&
              last_journal_state(t) == unsigned(z::State::unknown),
          "pre-create failure journals UNKNOWN and keeps accepted custody");
    check(t.journal.count() == 3,
          "accepted pre-create failure records ready/accepted/UNKNOWN only");
  }
  // A legal release is terminal. Replayed commands and late controller loss
  // must preserve both the in-memory state and the flushed responsibility log.
  {
    R2Fixture t;
    ControllerBoot boot(t.c);
    wchar_t name[] = L"controller";
    wchar_t *argv[] = {name};
    check(r::controller_process_entry(1, argv, boot) == 0,
          "normal R2 closed loop before terminal-release probe");
    const auto records = t.journal.count();
    check(t.custodian.state() == z::State::released &&
              !t.custodian.retained() &&
              last_journal_state(t) == unsigned(z::State::released),
          "normal release is terminal and has no retained custody");
    // Exercise the real Endpoint/Proxy error path, not just direct calls.
    const auto replay = t.proxy.accept_intent(t.f);
    check(replay.status != r::IoStatus::kOk &&
              t.custodian.state() == z::State::released &&
              !t.custodian.retained() && t.journal.count() == records,
          "replayed accept over the control channel cannot reopen released custody");
    // These previously entered unknown() and silently rewrote released.
    const auto duplicate_create = t.custodian.create();
    const auto duplicate_ack = t.custodian.acknowledge_identity({});
    bool known = true;
    const bool duplicate_resume = t.custodian.resume(known);
    check(!duplicate_create.created &&
              duplicate_ack.status != r::IoStatus::kOk &&
              !duplicate_resume && !known &&
              t.owner.base.creates == 1 && t.owner.base.resumes == 1 &&
              t.owner.base.close_calls == 1 &&
              t.custodian.state() == z::State::released &&
              !t.custodian.retained() && t.journal.count() == records &&
              last_journal_state(t) == unsigned(z::State::released),
          "duplicate create/ack/resume cannot rewrite terminal state or evidence");
    t.custodian.controller_lost();
    check(t.custodian.state() == z::State::released &&
              !t.custodian.retained() && t.journal.count() == records,
          "controller loss after legal release does not rewrite terminal state");
  }
}

void test_zero_resource_samples_rejected() {
  // Missing peaks or handles in any of the three processes are unavailable
  // measurements, not zero-cost observations.
  for (size_t proc = 0; proc < 3; ++proc) {
    for (int field = 0; field < 3; ++field) {
      R2Fixture t;
      if (field == 0)
        t.owner.samples[proc].peak_working_set = 0;
      if (field == 1)
        t.owner.samples[proc].peak_commit = 0;
      if (field == 2)
        t.owner.samples[proc].handles = 0;
      check(!t.custodian.sample() &&
                t.custodian.state() == z::State::unknown &&
                last_journal_state(t) == unsigned(z::State::unknown),
            "zero/absent three-process resource observation rejects");
    }
  }
}

void test_transport_loss_records_unknown() {
  R2Fixture t;
  const auto accepted = t.proxy.accept_intent(t.f);
  check(accepted.status == r::IoStatus::kOk &&
            t.custodian.state() == z::State::accepted,
        "proxy accepts before transport-loss probe");
  const auto before = t.journal.count();
  t.wire.drop_on_call = 2;
  check(!t.proxy.token(), "dropped control exchange fails");
  const auto calls = t.wire.calls;
  t.proxy.controller_lost();
  check(t.wire.calls == calls + 1,
        "controller loss attempts one STOP after a failed exchange");
  check(t.custodian.state() == z::State::unknown &&
            t.journal.count() == before + 1 &&
            last_journal_state(t) == unsigned(z::State::unknown),
        "Custodian records UNKNOWN when the controller disappears");
}

void test_image_binding() {
  R2Fixture good;
  check(z::match_images(good.f, good.lim, good.owner.images, 3),
        "all three measured executable hashes and object IDs match");
  auto hosts = good.owner.measure_hosts();
  check(z::match_images(good.f, good.lim, hosts, 2) &&
            !z::match_images(good.f, good.lim, hosts, 3),
        "pre-create hosts need no Worker; post-create requires Worker "
        "measurement");
  for (unsigned fault = 0; fault < 16; ++fault) {
    R2Fixture t;
    auto &image = t.owner.images[1];
    switch (fault) {
    case 0:
      image.sha256 = std::string(64, '9');
      break; // same object, different bytes
    case 1:
      image.sha256.clear();
      break;
    case 2:
      image.status = r::IoStatus::kDenied;
      break; // read failure
    case 3:
      image.status = r::IoStatus::kUnknown;
      break;
    case 4:
      image.object.volume_serial++;
      break;
    case 5:
      image.object.file_id[0]++;
      break;
    case 6:
      image.process_verified = false;
      break;
    case 7:
      image.origin = r::Origin::kUnavailable;
      break;
    case 8:
      image.sha256 = "UNKNOWN";
      break;
    case 9:
      t.owner.images[0].sha256 = std::string(64, '9');
      break;
    case 10:
      image.object = {};
      break;
    case 11:
      image = {};
      break;
    case 12:
      image.origin = r::Origin::kWindowsApi;
      break; // origin mismatch
    case 13:
      image = {};
      t.owner.measure_throw = true;
      break;
    case 14:
      image.security_sha256.clear();
      break; // missing independent Owner/DACL observation
    case 15:
      image.security_sha256[0] =
          image.security_sha256[0] == 'a' ? 'b' : 'a';
      break; // same bytes and File ID, drifted security digest
    }
    check(!z::match_images(t.f, t.lim, t.owner.images, 3),
          "bad process/hash/read/origin/object fails shared three-image gate");
    check(!t.c.begin(), "identity rejection stops begin before approval");
    t.finish();
    check(t.owner.accepts == 0 && t.owner.base.creates == 0 &&
              t.owner.base.resumes == 0 && t.proof.calls == 0 &&
              t.io.issues == 0 && t.io.burns == 0 && !t.custodian.retained(),
          "identity failure precedes Batch acceptance, Grant and Worker side "
          "effects");
    const auto attempts = t.owner.measurements;
    check(t.custodian.accept_intent(t.f).status != r::IoStatus::kOk,
          "failed identity cannot retry accept");
    t.custodian.create();
    bool known = false;
    check(!t.custodian.resume(known) && t.owner.measurements == attempts &&
              t.owner.accepts == 0 && t.owner.base.creates == 0 &&
              t.owner.base.resumes == 0 && t.io.burns == 0,
          "rejection is terminal: no remeasurement, retry, Grant consumption "
          "or Resume");
  }
  for (unsigned process = 0; process < 3; ++process) {
    auto images = good.owner.images;
    images[process].sha256 = std::string(64, '9');
    check(!z::match_images(good.f, good.lim, images, 3),
          "no process index can skip its approved SHA comparison");
    images = good.owner.images;
    images[process].security_sha256[0] =
        images[process].security_sha256[0] == 'a' ? 'b' : 'a';
    check(!z::match_images(good.f, good.lim, images, 3),
          "no process index can skip frozen Owner/DACL comparison");
  }
  {
    auto changed = good.f;
    auto &dacl = changed.manifest.pins[1].security_sha256;
    dacl[0] = dacl[0] == 'a' ? 'b' : 'a';
    changed.target.scope.wiring_manifest_sha256 = changed.manifest.hash();
    changed.target.grant.evidence_scope_id = changed.target.scope.hash();
    check(changed.valid() &&
              !z::match_images(changed, good.lim, good.owner.images, 2),
          "re-frozen target with drifted Custodian DACL cannot reuse measured bytes");
  }
  for (unsigned fault = 0; fault < 2; ++fault) {
    R2Fixture t;
    auto policy = t.lim;
    policy.custodian_sha256 = fault ? std::string(64, '9') : std::string{};
    z::Custodian candidate(t.f, policy, t.owner, t.proof, t.journal);
    check(candidate.accept_intent(t.f).status != r::IoStatus::kOk &&
              t.owner.accepts == 0 && !candidate.retained(),
          "missing or Limits-only frozen hash change denies before custody");
    candidate.create();
    bool known = false;
    check(!candidate.resume(known) && t.owner.base.creates == 0 &&
              t.owner.base.resumes == 0 && t.io.burns == 0 &&
              t.proof.calls == 0,
          "invalid frozen policy never reaches Grant/create/Resume");
  }
  auto missing = good.f;
  missing.manifest.pins.erase(missing.manifest.pins.begin() + 1);
  missing.target.scope.wiring_manifest_sha256 = missing.manifest.hash();
  missing.target.grant.evidence_scope_id = missing.target.scope.hash();
  check(missing.valid() &&
            !z::match_images(missing, good.lim, good.owner.images, 2),
        "Custodian image absent from approved artifact inventory denies");
  auto l = good.lim;
  l.custodian_sha256.clear();
  check(!z::match_images(good.f, l, good.owner.images, 2),
        "missing frozen Custodian hash rejects");
  l = good.lim;
  l.custodian_sha256 = std::string(64, '9');
  check(!z::match_images(good.f, l, good.owner.images, 2),
        "Limits-only change cannot bypass R2 manifest binding");
  auto f = good.f;
  f.manifest.r2_sha256 = l.hash();
  f.target.scope.wiring_manifest_sha256 = f.manifest.hash();
  f.target.grant.evidence_scope_id = f.target.scope.hash();
  check(f.valid() && !z::match_images(f, l, good.owner.images, 2),
        "even rebound target cannot substitute frozen hash for measured bytes");
  auto images = good.owner.images;
  images[1].sha256 = l.custodian_sha256;
  check(!z::match_images(f, l, images, 2),
        "new hash and measurement still require matching artifact inventory");
}

void test_approval_display_policy() {
  check(z::approval_display_ok(true, true, true, true, 100, 100),
        "approval accepts all controls with complete summary text");
  check(!z::approval_display_ok(false, true, true, true, 100, 100),
        "missing summary control rejects approval");
  check(!z::approval_display_ok(true, false, true, true, 100, 100),
        "missing reviewed checkbox rejects approval");
  check(!z::approval_display_ok(true, true, false, true, 100, 100),
        "missing suffix input rejects approval");
  check(!z::approval_display_ok(true, true, true, false, 100, 100),
        "missing approve button rejects approval");
  check(!z::approval_display_ok(true, true, true, true, 0, 100),
        "empty summary display rejects approval");
  check(!z::approval_display_ok(true, true, true, true, 99, 100),
        "short summary display rejects approval");
  check(z::approval_display_ok(true, true, true, true, 110, 100),
        "CRLF expansion of the summary remains acceptable");
}

} // namespace

int main() {
  test_three_process_closed_loop();
  test_custody_lifecycle_and_crashes();
  test_evidence_and_resource_budgets();
  test_state_gates_and_unknown_evidence();
  test_zero_resource_samples_rejected();
  test_transport_loss_records_unknown();
  test_image_binding();
  test_approval_display_policy();
  std::cout << "PASS: " << checks
            << " R2 custodian/identity/evidence/budget assertions; no Windows "
               "security operations\n";
}
