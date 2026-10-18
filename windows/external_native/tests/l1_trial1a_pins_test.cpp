#include "diagnostics/l1_trial1a_pins.h"
#include "tests/l1_s1_fixture.h"
namespace t = shiroha_l1_crypto::trial1a;
namespace {
t::PinPlan plan() {
  t::PinPlan p;
  p.entry.preparation = request();
  p.entry.pid = 5;
  p.entry.creation = 55;
  p.entry.process_owner = "ENTRY-PROCESS-OWNER";
  p.entry.image_id = p.entry.preparation.frozen.manifest.pins[0].id;
  p.entry.total_budget = t::ceiling(p.entry.preparation);
  const auto &q = p.entry.preparation;
  auto paths =
      s::parent_paths(q.evidence_directory + "\\evidence-controller.r2");
  for (size_t i = 0; i < q.evidence_parents.size(); ++i) {
    p.objects.push_back(
        {q.evidence_parents[i], paths[i], L"FAKE-OWNER", i ? i - 1 : 0, true});
    p.evidence_parents.push_back(i);
    if (i < q.parents.size())
      p.parents.push_back(i); // shared, not reopened
  }
  r::Pin directory = q.parents[0];
  directory.id = "ARTIFACT-PARENT";
  directory.object.file_id[0] = 7;
  directory.bytes_sha256 = s::metadata_digest(directory.object);
  const auto parent = p.objects.size();
  p.objects.push_back(
      {directory, "C:\\ARTIFACTS", L"FAKE-SYSTEM-OWNER", 0, true});
  for (const auto &pin : q.frozen.manifest.pins) {
    p.artifacts.push_back(p.objects.size());
    p.objects.push_back({pin, "C:\\ARTIFACTS\\" + pin.id + ".exe",
                         L"FAKE-OWNER", parent, false});
  }
  p.budget = t::acquisition_ceiling(p);
  check(p.valid(),
        "independently frozen synthetic shared acquisition inventory");
  return p;
}
struct Process final : t::ProcessPort {
  t::ProcessObservation observation;
  r::Origin source = r::Origin::kFake;
  unsigned calls = 0;
  r::Origin origin() const noexcept override { return source; }
  t::ProcessObservation measure() override {
    ++calls;
    return observation;
  }
};
struct Pins final : t::PinPort {
  Ops &ops;
  Process &process;
  r::Origin source = r::Origin::kFake;
  std::vector<t::AcquiredPin> retained;
  std::vector<size_t> closes;
  unsigned opens = 0, binds = 0, releases = 0;
  size_t fail_at = size_t(-1), close_fail = size_t(-1);
  unsigned drift = 0;
  bool bad_bind = false, bad_release = false, throws = false;
  std::string owner;
  Pins(Ops &o, Process &p) : ops(o), process(p) {}
  r::Origin origin() const noexcept override { return source; }
  t::AcquiredPin acquire(size_t i, const t::PinInput &p,
                         uintptr_t parent) override {
    ++opens;
    if (i != retained.size())
      return {}; // same Owner rejects replay/reconstruction
    check(i ? parent == retained[p.parent].handle : parent == 0,
          "only exact retained parent used for child open");
    auto measured = p.expected;
    if (!p.directory)
      measured.bytes_sha256.clear();
    t::AcquiredPin a{100 + i, measured, true, p.directory,
                     false,   false,    true, true};
    if (i == fail_at) {
      if (throws)
        throw 1;
      switch (drift) {
      case 0:
        a.handle = 0;
        break;
      case 1:
        ++a.measured.object.file_id[0];
        break;
      case 2:
        ++a.measured.object.volume_serial;
        break;
      case 3:
        ++a.measured.parent.file_id[0];
        break;
      case 4:
        a.reparse = true;
        break;
      case 5:
        a.measured.security_sha256 = std::string(64, '0');
        break;
      case 6:
        a.owner_checked = false;
        break;
      case 7:
        a.measured.owner = "UNKNOWN-OWNER";
        break;
      case 8:
        a.delete_pending = true;
        break;
      case 9:
        a.exact_path = false;
        break;
      case 10:
        a.c_ntfs = false;
        break;
      case 11:
        a.directory = !a.directory;
        break;
      case 12:
        a.handle = 100;
        break;
      case 13:
        a.measured.bytes_sha256 = std::string(64, '0');
        break;
      }
    }
    retained.push_back(a);
    return a;
  }
  s::Handoff bind(const t::PinPlan &p,
                  const std::vector<t::AcquiredPin> &a) override {
    ++binds;
    check(a.size() == retained.size() && binds == 1,
          "one borrow of full retained inventory");
    owner = p.entry.preparation.frozen.manifest.pin_owner;
    // Fake measurements read this acquired inventory, not a separate target
    // copy.
    for (size_t i = 0; i < p.parents.size(); ++i)
      ops.q.parents[i] = a[p.parents[i]].measured;
    const auto &image = a[p.artifacts[0]].measured;
    process.observation = {
        source,       p.entry.pid,           p.entry.creation,
        image.object, image.security_sha256, true};
    return {bad_bind ? r::IoStatus::kUnknown : r::IoStatus::kOk, owner,
            p.hash(), t::borrow_hash(p, a)};
  }
  s::Handoff release_borrow(const std::string &request,
                            const std::string &hash) override {
    ++releases;
    check(ops.root_closes == 1 && ops.evidence_closes == 1,
          "upstream borrows end only after root and evidence settlement");
    return {bad_release ? r::IoStatus::kUnknown : r::IoStatus::kOk, owner,
            request, hash};
  }
  bool close(size_t i, const std::string &o, uintptr_t h) override {
    check(releases == 1 && o == owner && h == retained[i].handle &&
              i + closes.size() + 1 == retained.size(),
          "sole owner closes exact handles in reverse dependency order");
    closes.push_back(i);
    return i != close_fail;
  }
};
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
