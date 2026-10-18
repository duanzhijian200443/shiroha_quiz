#include "diagnostics/l1_trial1a_real.h"
#include "tests/l1_trial1a_fixture.h"
#include <set>
namespace c = shiroha_l1_crypto;
namespace {
t::Invocation invocation() {
  t::Invocation q;
  q.plan = plan();
  q.plan.entry.pid = 0;
  q.plan.entry.creation = 0;
  q.case_id = "CASE-1A";
  q.permit_owner = "PERMIT-OWNER";
  q.resources = {100000, 200000, 256};
  q.observations = 256;
  q.duration_ms = 30000;
  q.budget = t::invocation_ceiling(q);
  q.reviewed_binding = q.hash();
  check(q.valid(), "reviewed template has NO prefilled process identity");
  return q;
}
struct Store {
  std::set<std::string> tombstones;
};
struct Control final : t::InvocationPort {
  t::Invocation q;
  Ops &ops;
  Store &store;
  Disk disk;
  std::unique_ptr<z::PersistentEvidence> evidence;
  r::Origin source = r::Origin::kFake;
  unsigned approvals = 0, observes = 0, attaches = 0, consumes = 0,
           finishes = 0, closes = 0, fail_observation = 0, drift = 0;
  bool approved = true, bad_reply = false, crash = false, lost_ack = false,
       failed_close = false;
  Control(t::Invocation v, Ops &o, Store &s)
      : q(std::move(v)), ops(o), store(s) {}
  r::Origin origin() const noexcept override { return source; }
  bool approve(const c::e4::ApprovalPromptModel &p,
               c::e4::ApprovalUiResponse &a) override {
    ++approvals;
    check(p.target_hash == q.hash() &&
              p.summary.find("TRIAL 1A ONLY") != std::string::npos,
          "same bounded UI model binds 1A packet, never 1B Grant");
    a.completed = a.checked = approved;
    a.suffix = p.suffix;
    a.displayed_hash = bad_reply ? std::string(64, '0') : p.target_hash;
    return approved;
  }
  t::Observation observe() override {
    ++observes;
    t::Observation m;
    m.runtime = ops.identity();
    const auto &g = q.plan.entry.preparation.frozen.target.grant;
    m.clock = {g.window_start_ms + 1 + observes, 1000 + observes,
               ops.observed_creation, true};
    m.resources = {m.clock.mono, 100, 200, 12, 0};
    if (observes == fail_observation) {
      switch (drift) {
      case 0:
        m.runtime.facts.sid = L"OTHER";
        break;
      case 1:
        m.runtime.facts.primary_medium = false;
        break;
      case 2:
        m.runtime.facts.pid = observes == 1 ? 0 : m.runtime.facts.pid + 1;
        break;
      case 3:
        m.runtime.facts.creation_time =
            observes == 1 ? 0 : m.runtime.facts.creation_time + 1;
        break;
      case 4:
        m.runtime.facts.os = std::string(64, '0');
        break;
      case 5:
        m.runtime.device_sha256 = std::string(64, '0');
        break;
      case 6:
        m.resources.peak_working_set = q.resources.working + 1;
        break;
      case 7:
        m.resources.peak_commit = q.resources.commit + 1;
        break;
      case 8:
        m.resources.handles = q.resources.handles + 1;
        break;
      case 9:
        m.clock.valid = false;
        break;
      case 10:
        m.clock.utc = g.window_end_ms;
        break;
      case 11:
        m.clock.mono = 1000 + q.duration_ms + 1;
        break;
      case 12:
        m.clock.utc = 1;
        break;
      case 13:
        m.runtime.facts.origin = r::Origin::kWindowsApi;
        break;
      case 14:
        m.resources.peak_commit = 0;
        break;
      default:
        throw 1;
      }
    }
    return m;
  }
  bool attach(const t::PinPlan &p) override {
    ++attaches;
    check(p.entry.pid == ops.observed_pid &&
              p.entry.creation == ops.observed_creation &&
              p.entry.invocation_binding == q.hash(),
          "runtime PID/time observed after current entry start and bound in "
          "plan");
    ops.q = p.entry.preparation;
    return true;
  }
  r::SinkReceipt consume(const r::Record &r) override {
    ++consumes;
    auto key = s::pin_hash(q.plan.entry.preparation.evidence_parents.back());
    // Persistent directory identity is independent of PID, owner label and
    // process lifetime. FILE_CREATE leaves a tombstone even before first write.
    if (!store.tombstones.insert(key).second)
      return {};
    if (crash)
      throw 1;
    const auto &f = q.plan.entry.preparation.frozen;
    evidence = std::make_unique<z::PersistentEvidence>(
        disk, f.target.grant.batch_id, f.hash(), q.permit_owner, 2);
    check(r.consumed && r.pid == ops.observed_pid &&
              r.creation_time == ops.observed_creation,
          "durable consumed evidence binds observed startup identity");
    auto a = evidence->preserve(r);
    if (lost_ack)
      a.record_sha256 = std::string(64, '0');
    return a;
  }
  r::SinkReceipt finish(const r::Record &r) override {
    ++finishes;
    check(ops.root_closes == 1 && ops.evidence_closes == 1 &&
              r.security == c::OfflineVerdict::kNotRun && !r.handles_closed,
          "permit final ACK precedes ancestor close and makes no aggregate "
          "PASS claim");
    return evidence ? evidence->preserve(r) : r::SinkReceipt{};
  }
  bool close_permit(const std::string &o) override {
    ++closes;
    check(o == q.permit_owner && finishes == 1, "sole permit owner close once");
    return !failed_close;
  }
};
struct RealFixture {
  t::Invocation q;
  Ops ops;
  Process process;
  Pins pins;
  Disk disk;
  S1Sink sink;
  Control control;
  t::RealEntry entry;
  RealFixture(Store &store, t::Invocation v = invocation())
      : q(std::move(v)), ops(q.plan.entry.preparation), pins(ops, process),
        sink(disk, q.plan.entry.preparation), control(q, ops, store),
        entry(q, control, pins, ops, process, sink) {}
};
void success() {
  Store store;
  RealFixture f(store);
  f.ops.observed_pid = 123;
  f.ops.observed_creation = 4567;
  check(f.entry.run_offline(), "full controlled invocation -> acquisition -> "
                               "Entry -> S1 -> R2 -> settlement");
  const auto &r = f.entry.result();
  check(r.settled && r.consumed && r.prepared && !r.unknown && r.pid == 123 &&
            r.creation == 4567 && r.entry_starts == 1 && r.approvals == 1 &&
            r.consume_attempts == 1 && r.finish_attempts == 1 &&
            r.permit_closes == 1,
        "single entry start, measured binding, consumption and explicit "
        "settlement");
  check(f.ops.creates == 1 && f.process.calls == 4 &&
            f.pins.closes.size() == f.q.plan.objects.size() &&
            f.control.disk.writes == 2 && f.disk.writes == 2 &&
            r.peak.handles == 12,
        "existing algorithm and 8192-byte evidence reused, resource peak "
        "observed through closes");
  for (size_t i = 0; i < s::counter_count; ++i)
    check(r.reserved[i] <= f.q.budget[i],
          "full operation and observation envelope never exceeds user budget");
  check(!f.entry.run_offline() && f.control.approvals == 1,
        "same object cannot approve or execute twice");
  RealFixture restarted(store);
  restarted.ops.observed_pid = 124;
  restarted.ops.observed_creation = 9999;
  check(!restarted.entry.run_offline() && restarted.ops.creates == 0 &&
            restarted.process.calls == 1 &&
            restarted.control.disk.writes == 0 && restarted.pins.closes.empty(),
        "new process cannot replay spent directory permit");
}
void preflight() {
  for (unsigned kind = 0; kind < 10 + s::counter_count; ++kind) {
    Store store;
    auto q = invocation();
    switch (kind) {
    case 0:
      q.plan.entry.pid = 5;
      break;
    case 1:
      q.plan.entry.creation = 55;
      break;
    case 2:
      q.reviewed_binding.clear();
      break;
    case 3:
      q.case_id.clear();
      break;
    case 4:
      q.permit_owner.clear();
      break;
    case 5:
      q.observations = 8193;
      break;
    case 6:
      q.duration_ms = 30001;
      break;
    case 7:
      q.resources.handles = 0;
      break;
    case 8:
      q.plan.objects[1].expected.security_sha256.clear();
      break;
    case 9:
      q.plan.entry.preparation.frozen.target.grant.review_sha256.clear();
      break;
    default:
      --q.budget[kind - 10];
      break;
    }
    RealFixture f(store, q);
    check(!f.entry.run_offline() && f.control.approvals == 0 &&
              f.control.observes == 0 && f.pins.opens == 0 &&
              f.ops.identities == 0 && store.tombstones.empty(),
          "missing review/target/account/scope/budget denies before external "
          "I/O");
  }
  for (unsigned kind = 0; kind < 3; ++kind) {
    Store store;
    RealFixture f(store);
    if (!kind)
      f.control.approved = false;
    else if (kind == 1)
      f.control.bad_reply = true;
    else
      f.control.source = r::Origin::kWindowsApi;
    check(!f.entry.run_offline() && !f.entry.run_offline() &&
              f.control.observes == 0 && f.pins.opens == 0 &&
              f.ops.creates == 0,
          "refused/counterfeit confirmation or mixed Windows port never "
          "reaches primitives");
  }
}
void failures() {
  for (unsigned at = 1; at <= 4; ++at) {
    Store store;
    RealFixture f(store);
    f.process.fail_at = at;
    check(!f.entry.run_offline() && !f.entry.result().settled &&
              f.process.calls == at && f.pins.closes.empty(),
          "running image/Token rejection at preconsume or any Entry gate never "
          "continues");
    if (at == 1)
      check(f.control.consumes == 0 && f.ops.creates == 0,
            "wrong running image cannot even consume the permit");
    if (at <= 3)
      check(f.ops.creates == 0, "process drift before create denies root");
  }
  for (unsigned at : {1u, 3u, 30u, 70u})
    for (unsigned kind = 0; kind < 16; ++kind) {
      Store store;
      RealFixture f(store);
      f.control.fail_observation = at;
      f.control.drift = kind;
      check(!f.entry.run_offline() && !f.entry.result().settled &&
                f.entry.result().unknown && !f.entry.run_offline(),
            "permission/process/OS/resource/UTC/monotonic drift or exception "
            "stops entire chain");
      check(f.control.observes == at,
            "no further observation or operation after monitor failure");
    }
  for (unsigned kind = 0; kind < 9; ++kind) {
    Store store;
    RealFixture f(store);
    switch (kind) {
    case 0:
      f.control.crash = true;
      break;
    case 1:
      f.control.lost_ack = true;
      break;
    case 2:
      f.control.disk.short_write = true;
      break;
    case 3:
      f.control.disk.fail_flush = 1;
      break;
    case 4:
      f.control.disk.fail_write = 2;
      break;
    case 5:
      f.control.failed_close = true;
      break;
    case 6:
      f.sink.lost_ack = 2;
      break;
    case 7:
      f.ops.close_failure = true;
      break;
    case 8:
      f.pins.bad_bind = true;
      break;
    }
    check(!f.entry.run_offline() && !f.entry.result().settled &&
              f.entry.result().unknown && f.pins.closes.empty(),
          "crash/partial/Flush/lost ACK/evidence/close UNKNOWN retains "
          "custody, no upstream close");
    if (kind < 4)
      check(f.ops.creates == 0, "consumption ambiguity prevents root create");
    if (kind != 8) {
      RealFixture restart(store);
      check(!restart.entry.run_offline() && restart.ops.creates == 0,
            "empty or partial tombstone survives crash, new owner object "
            "cannot replay");
    }
  }
  Store store;
  auto q = invocation();
  q.observations = 2;
  q.budget = t::invocation_ceiling(q);
  q.reviewed_binding = q.hash();
  RealFixture f(store, q);
  check(!f.entry.run_offline() && f.control.observes == 2 && f.ops.creates == 0,
        "small approved sampling budget is enforced, never auto-increased");
}
} // namespace
int main() {
  success();
  preflight();
  failures();
  std::cout << "PASS: " << checks
            << " Trial 1A real-entry assertions; OFFLINE/FAKE only\n";
}
