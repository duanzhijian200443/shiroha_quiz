#ifndef SHIROHA_L1_TRIAL1A_FIXTURE_H_
#define SHIROHA_L1_TRIAL1A_FIXTURE_H_
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
  unsigned fail_at = 0;
  r::Origin origin() const noexcept override { return source; }
  t::ProcessObservation measure() override {
    ++calls;
    auto m = observation;
    if (calls == fail_at)
      m.checked = false;
    return m;
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
} // namespace
#endif
