#include "diagnostics/l1_trial1a_entry.h"
#include "tests/l1_s1_fixture.h"
namespace t = shiroha_l1_crypto::trial1a;
namespace {
t::Target target() {
  t::Target v;
  v.preparation = request();
  v.pid = 5;
  v.creation = 55;
  v.process_owner = "ENTRY-PROCESS-OWNER";
  v.image_id = v.preparation.frozen.manifest.pins[0].id;
  v.total_budget = t::ceiling(v.preparation);
  check(v.valid(), "complete independently supplied entry target");
  return v;
}
struct Process final : t::ProcessPort {
  t::ProcessObservation observation;
  r::Origin source = r::Origin::kFake;
  unsigned calls = 0;
  bool throws = false;
  unsigned drift_call = 0;
  explicit Process(const t::Target &v) {
    const auto &p = v.preparation.frozen.manifest.pins[0];
    observation = {source, v.pid, v.creation, p.object, p.security_sha256,
                   true};
  }
  r::Origin origin() const noexcept override { return source; }
  t::ProcessObservation measure() override {
    ++calls;
    if (throws)
      throw 1;
    if (calls == drift_call)
      ++observation.image.file_id[0];
    return observation;
  }
};
struct EntryFixture {
  t::Target v = target();
  Ops ops{v.preparation};
  Disk disk;
  S1Sink sink{disk, v.preparation};
  Process process{v};
  t::Entry entry{v, ops, sink, process};
};
void success() {
  EntryFixture f;
  check(f.entry.run_offline(), "actual entry composition runs S1 end to end");
  check(
      f.process.calls == 3 && f.entry.process_attempts() == 3 &&
          f.ops.identities == 1 && f.ops.creates == 1 && f.ops.roots == 2 &&
          f.ops.parent_calls == 8 && f.ops.handoffs == 1 &&
          f.ops.artifacts == 3 && f.entry.result().artifact_read_calls == 768,
      "fixed process, independent identity, one create and identity rechecks");
  check(f.disk.writes == 2 && f.disk.flushes == 2 &&
            f.disk.bytes[0].size() == z::kRecordBytes &&
            f.entry.result().last.stage == r::Stage::kFinal &&
            f.entry.result().evidence_preserved,
        "intent and final use real R2 encoder and durable ACK semantics");
  check(!f.entry.close_root_once("OTHER") &&
            !f.entry.close_evidence_once("OTHER"),
        "foreign owner cannot settle");
  check(f.entry.close_root_once(f.v.preparation.frozen.manifest.pin_owner) &&
            f.entry.close_evidence_once(
                f.v.preparation.frozen.manifest.evidence_owner),
        "unique named root/evidence owner explicitly settles after ACK");
  check(!f.entry.close_root_once(f.v.preparation.frozen.manifest.pin_owner) &&
            !f.entry.close_evidence_once(
                f.v.preparation.frozen.manifest.evidence_owner) &&
            f.ops.root_closes == 1 && f.ops.evidence_closes == 1,
        "no destructor/borrowed-owner/repeated close");
  check(f.entry.reserved() == f.v.total_budget,
        "full process/S1/close ledger equals fixed approved budget");
  check(!f.entry.run_offline() && !f.entry.run_windows() && f.ops.creates == 1,
        "batch never retried or switched to real origin");
  EntryFixture other;
  auto changed = other.v;
  changed.process_owner = "ANOTHER-OWNER";
  t::Entry e(changed, other.ops, other.sink, other.process);
  check(e.run_offline() && other.entry.result().last.sequence == 0 &&
            e.result().last.manifest != f.entry.result().last.manifest,
        "entry binding including owner committed by persisted ledger");
}
void validation() {
  for (size_t i = 0; i < s::counter_count; ++i) {
    EntryFixture f;
    auto v = f.v;
    --v.total_budget[i];
    t::Entry e(v, f.ops, f.sink, f.process);
    check(!e.run_offline() && f.process.calls == 0 && f.ops.opens == 0 &&
              f.ops.creates == 0,
          "each incomplete operation dimension rejected before measurement");
  }
  for (unsigned i = 0; i < 9; ++i) {
    EntryFixture f;
    auto v = f.v;
    switch (i) {
    case 0:
      v.pid = 0;
      break;
    case 1:
      v.creation = 0;
      break;
    case 2:
      v.process_owner.clear();
      break;
    case 3:
      v.image_id = "MISSING";
      break;
    case 4:
      v.image_id = v.preparation.frozen.manifest.pins[1].id;
      break;
    case 5:
      --v.total_budget[s::os_calls];
      break;
    case 6:
      ++v.total_budget[s::handles_closed];
      break;
    case 7:
      --v.preparation.budget[s::evidence_flushes];
      break;
    case 8:
      v.preparation.entry_binding = std::string(64, '0');
      break;
    }
    t::Entry e(v, f.ops, f.sink, f.process);
    check(!e.run_offline() && !e.run_offline() && f.process.calls == 0 &&
              f.ops.identities == 0 && f.ops.opens == 0 && f.ops.creates == 0,
          "invalid fixed input or incomplete budget rejects before ANY I/O");
  }
  for (unsigned i = 0; i < 7; ++i) {
    EntryFixture f;
    auto &m = f.process.observation;
    switch (i) {
    case 0:
      ++m.pid;
      break;
    case 1:
      ++m.creation;
      break;
    case 2:
      ++m.image.file_id[0];
      break;
    case 3:
      m.security_sha256 = std::string(64, '0');
      break;
    case 4:
      m.checked = false;
      break;
    case 5:
      m.origin = r::Origin::kWindowsApi;
      break;
    case 6:
      f.process.throws = true;
      break;
    }
    check(!f.entry.run_offline() && f.entry.state() == s::State::unknown &&
              !f.entry.run_offline() && f.process.calls == 1 &&
              f.ops.opens == 0 && f.ops.creates == 0 && f.ops.root_closes == 0,
          "independent process/permissions/temporary-close drift is UNKNOWN no "
          "retry");
  }
  EntryFixture f;
  f.ops.q.frozen.target.sid = L"OTHER";
  check(
      !f.entry.run_offline() && f.ops.creates == 0,
      "independent SID permissions cannot be replaced by configured identity");
}
void failures() {
  for (unsigned call : {2u, 3u}) {
    EntryFixture f;
    f.process.drift_call = call;
    check(!f.entry.run_offline() && f.entry.state() == s::State::unknown &&
              f.ops.creates == (call == 2 ? 0u : 1u) && f.ops.handoffs == 0 &&
              !f.entry.run_offline() && f.process.calls == call,
          "process drift before create or Pin handoff stops that operation");
  }
  for (unsigned i = 0; i < 10; ++i) {
    EntryFixture f;
    switch (i) {
    case 0:
      f.ops.bad_artifact = true;
      break;
    case 1:
      f.ops.bad_identity = true;
      break;
    case 2:
      f.ops.drift_call = 3;
      break;
    case 3:
      f.ops.creation = s::Creation::exists;
      break;
    case 4:
      f.ops.creation = s::Creation::unknown;
      break;
    case 5:
      f.ops.root_identity_drift = true;
      break;
    case 6:
      f.ops.bad_handoff = true;
      break;
    case 7:
      f.disk.fail_flush = 2;
      break;
    case 8:
      f.sink.lost_ack = 2;
      break;
    case 9:
      f.disk.short_write = true;
      break;
    }
    check(!f.entry.run_offline() && !f.entry.run_offline() &&
              f.ops.creates <= 1 && f.disk.writes <= 2 &&
              !f.entry.close_root_once(
                  f.v.preparation.frozen.manifest.pin_owner) &&
              !f.entry.close_evidence_once(
                  f.v.preparation.frozen.manifest.evidence_owner) &&
              f.ops.root_closes == 0 && f.ops.evidence_closes == 0,
          "drift/collision/unknown/evidence failure stops without close or "
          "retry");
    for (size_t j = 0; j < s::counter_count; ++j)
      check(f.entry.reserved()[j] <= f.v.total_budget[j],
            "failure ledger bounded");
  }
  EntryFixture f;
  f.ops.close_failure = true;
  check(
      f.entry.run_offline() &&
          !f.entry.close_root_once(f.v.preparation.frozen.manifest.pin_owner) &&
          f.entry.state() == s::State::unknown &&
          !f.entry.close_evidence_once(
              f.v.preparation.frozen.manifest.evidence_owner) &&
          f.ops.root_closes == 1 && f.ops.evidence_closes == 0,
      "failed close burns sole owner's attempt and blocks subsequent "
      "settlement");
}
void closed() {
  for (auto o : {r::Origin::kWindowsApi, r::Origin::kIndependentBuild,
                 r::Origin::kUnavailable}) {
    EntryFixture f;
    f.process.source = o;
    check(!f.entry.run_offline() && f.process.calls == 0 && f.ops.creates == 0,
          "non-Fake process origin denied before measurement");
    EntryFixture g;
    g.ops.source = o;
    check(!g.entry.run_offline() && g.process.calls == 0 && g.ops.creates == 0,
          "non-Fake operation origin denied before measurement");
  }
  EntryFixture f;
  check(!f.entry.run_windows() && !f.entry.run_offline() &&
            f.process.calls == 0 && f.ops.identities == 0 && f.ops.creates == 0,
        "even complete Fake target cannot activate Windows entry");
  wchar_t argument[] = L"--authorize=true";
  wchar_t *argv[] = {argument};
  check(t::process_entry(1, argv) == 10 && t::process_entry(0, nullptr) == 10,
        "CLI entry ignores input and unconditionally refuses execution");
}
} // namespace
int main() {
  success();
  validation();
  failures();
  closed();
  std::cout << "PASS: " << checks
            << " Trial 1A entry assertions; OFFLINE/FAKE only\n";
}
