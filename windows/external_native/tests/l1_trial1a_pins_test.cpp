#include "tests/l1_trial1a_fixture.h"
namespace {
struct AcquisitionFixture {
  t::PinPlan p = plan();
  Ops ops{p.entry.preparation};
  Disk disk;
  S1Sink sink{disk, p.entry.preparation};
  Process process;
  Pins pins{ops, process};
  t::Acquisition run{p, pins, ops, sink, process};
};
void success() {
  AcquisitionFixture f;
  check(f.run.run_offline() && f.run.state() == s::State::pinned &&
            !f.run.settled() && f.ops.creates == 1 && f.ops.handoffs == 1 &&
            f.pins.opens == f.p.objects.size() && f.process.calls == 3 &&
            f.run.result().artifact_read_calls == 768 && f.disk.writes == 2,
        "acquire -> match -> borrow -> real S1 -> root Pin ACK -> evidence");
  check(f.p.objects.size() == 7 && f.p.parents[0] == f.p.evidence_parents[0] &&
            f.p.artifacts[0] == 4,
        "shared ancestors and image acquired once");
  check(f.run.result().root.object.valid() &&
            f.run.result().root.id == f.p.entry.preparation.root_id,
        "new root needs no frozen File ID and binds observed identity after "
        "create");
  check(!f.run.settle_once(
            "OTHER", f.p.entry.preparation.frozen.manifest.evidence_owner),
        "foreign owner cannot burn legal settlement");
  check(
      f.run.settle_once(f.p.entry.preparation.frozen.manifest.pin_owner,
                        f.p.entry.preparation.frozen.manifest.evidence_owner) &&
          f.run.settled() && f.pins.closes.size() == f.p.objects.size() &&
          f.run.reserved() == f.p.budget,
      "one full budget includes every final close");
  check(!f.run.run_offline() &&
            !f.run.settle_once(
                f.p.entry.preparation.frozen.manifest.pin_owner,
                f.p.entry.preparation.frozen.manifest.evidence_owner),
        "no replay or duplicate close");
  auto p = f.p;
  p.objects[0].owner_sid = L"DIFFERENT-FROZEN-OWNER";
  check(p.valid() && p.hash() != f.p.hash(),
        "actual Owner SID frozen separately from handle owner");
  AcquisitionFixture other;
  t::Acquisition changed(p, other.pins, other.ops, other.sink, other.process);
  check(
      changed.run_offline() &&
          changed.result().last.manifest != f.run.result().last.manifest,
      "changed frozen acquisition Owner commits a different R2 action digest");
}
void validation() {
  for (unsigned kind = 0; kind < 19 + s::counter_count; ++kind) {
    AcquisitionFixture f;
    auto p = f.p;
    switch (kind) {
    case 0:
      p.objects[1].expected.owner.clear();
      break;
    case 1:
      p.objects[1].owner_sid.clear();
      break;
    case 2:
      p.objects[1].expected.object = p.objects[0].expected.object;
      break;
    case 3:
      p.objects[1].parent = 1;
      break;
    case 4:
      p.objects[1].path = "C:\\OTHER";
      break;
    case 5:
      p.objects[4].expected.bytes_sha256 = std::string(64, '0');
      break;
    case 6:
      p.objects[1].expected.security_sha256.clear();
      break;
    case 7:
      p.artifacts[0] = 100;
      break;
    case 8:
      p.parents.pop_back();
      break;
    case 9:
      p.evidence_parents.pop_back();
      break;
    case 10:
      p.objects.push_back(p.objects[0]);
      p.budget = t::acquisition_ceiling(p);
      break;
    case 11:
      p.objects[3].expected.parent.file_id[0]++;
      break;
    case 12:
      p.objects[4].path = "C:\\ARTIFACTS\\..\\escape";
      break;
    case 13:
      p.objects[4].path = "C:\\ARTIFACTS\\file:stream";
      break;
    case 14:
      p.objects[0].path = "D:\\";
      break;
    case 15:
      p.objects[3].path = p.entry.preparation.frozen.target.scope.directory;
      break;
    case 16:
      p.entry.acquisition_binding = std::string(64, '0');
      break;
    case 17:
      p.entry.process_owner.clear();
      break;
    case 18:
      p.objects[3].expected.bytes_sha256 = std::string(64, '0');
      break;
    default:
      --p.budget[kind - 19];
      break;
    }
    t::Acquisition run(p, f.pins, f.ops, f.sink, f.process);
    check(!run.run_offline() && !run.run_offline() && f.pins.opens == 0 &&
              f.ops.opens == 0 && f.ops.creates == 0,
          "unauthorized/missing/incomplete inventory or budget denies before "
          "I/O");
  }
}
void failures() {
  for (size_t at = 0; at < 7; ++at)
    for (unsigned drift = 0; drift < 14; ++drift) {
      if (!at && drift == 12)
        continue;
      AcquisitionFixture f;
      f.pins.fail_at = at;
      f.pins.drift = drift;
      check(!f.run.run_offline() && f.run.state() == s::State::unknown &&
                f.ops.creates == 0 && f.pins.binds == 0 &&
                f.pins.opens == at + 1 && !f.run.run_offline() &&
                f.pins.closes.empty(),
            "failed acquisition/identity/ACL/reparse/path/type/ambiguous owner "
            "never binds or creates");
    }
  for (unsigned kind = 0; kind < 9; ++kind) {
    AcquisitionFixture f;
    switch (kind) {
    case 0:
      f.pins.bad_bind = true;
      break;
    case 1:
      f.ops.bad_artifact = true;
      break;
    case 2:
      f.ops.bad_handoff = true;
      break;
    case 3:
      f.ops.creation = s::Creation::exists;
      break;
    case 4:
      f.ops.root_identity_drift = true;
      break;
    case 5:
      f.sink.lost_ack = 2;
      break;
    case 6:
      f.pins.fail_at = 2;
      f.pins.throws = true;
      break;
    case 7:
      f.ops.drift_call = 3;
      break;
    case 8:
      f.ops.drift_call = 3;
      f.ops.drift_kind = 4;
      break;
    }
    check(!f.run.run_offline() && !f.run.run_offline() && !f.run.settled() &&
              f.ops.creates <= 1 && f.pins.closes.empty() &&
              !f.run.settle_once(
                  f.p.entry.preparation.frozen.manifest.pin_owner,
                  f.p.entry.preparation.frozen.manifest.evidence_owner),
          "unknown handoff/hash/parent drift/root/evidence failure no PASS "
          "cleanup or retry");
    if (!kind)
      check(f.ops.creates == 0, "upstream UNKNOWN prevents creation");
    auto used = f.run.reserved();
    for (size_t i = 0; i < s::counter_count; ++i)
      check(used[i] <= f.p.budget[i], "failure fits full budget");
  }
  for (unsigned kind = 0; kind < 3; ++kind) {
    AcquisitionFixture f;
    if (kind == 0)
      f.pins.bad_release = true;
    if (kind == 1)
      f.pins.close_fail = 5;
    if (kind == 2)
      f.ops.close_failure = true;
    check(f.run.run_offline() &&
              !f.run.settle_once(
                  f.p.entry.preparation.frozen.manifest.pin_owner,
                  f.p.entry.preparation.frozen.manifest.evidence_owner) &&
              f.run.state() == s::State::unknown && !f.run.settled() &&
              !f.run.settle_once(
                  f.p.entry.preparation.frozen.manifest.pin_owner,
                  f.p.entry.preparation.frozen.manifest.evidence_owner),
          "UNKNOWN release/close is terminal with no retry or settled PASS");
    check(f.pins.closes.size() == (kind == 1 ? 2u : 0u),
          "stop at first uncertain close");
  }
}
void gates() {
  for (auto origin : {r::Origin::kWindowsApi, r::Origin::kIndependentBuild,
                      r::Origin::kUnavailable})
    for (unsigned which = 0; which < 3; ++which) {
      AcquisitionFixture f;
      if (!which)
        f.pins.source = origin;
      else if (which == 1)
        f.ops.source = origin;
      else
        f.process.source = origin;
      check(!f.run.run_offline() && f.pins.opens == 0 && f.ops.identities == 0,
            "every non-Fake port rejected before acquisition");
    }
  AcquisitionFixture f;
  check(!f.run.run_windows() && !f.run.run_offline() && f.pins.opens == 0 &&
            f.ops.creates == 0,
        "complete synthetic plan cannot activate Windows");
}
} // namespace
int main() {
  success();
  validation();
  failures();
  gates();
  std::cout << "PASS: " << checks
            << " Trial 1A Pin acquisition assertions; OFFLINE/FAKE only\n";
}
