#include "tests/l1_s1_fixture.h"
namespace {
void success_and_ownership() {
  const auto max = s::ceiling(16, 64, 16);
  check(max[s::os_calls] == 74018 && max[s::directories] == 1196 &&
            max[s::files] == 199 && max[s::security_reads] == 1460 &&
            max[s::handles_acquired] == 4 && max[s::handles_closed] == 4 &&
            max[s::security_sets] == 2 && max[s::evidence_bytes] == 16384,
        "reviewable source envelope includes all owned objects");
  S1Fixture f;
  check(!f.preparation.result().root.object.valid(),
        "no fabricated pre-create File ID");
  check(f.preparation.run_offline(),
        "one-shot preparation succeeds only offline");
  auto &r = f.preparation.result();
  check(r.state == s::State::pinned && r.created &&
            r.root.object == f.ops.actual.object,
        "created actual root identity fixed and handed off");
  check(f.ops.creates == 1 && f.ops.roots == 2 && f.ops.parent_calls == 8 &&
            f.ops.handoffs == 1,
        "exact bounded create/root/full-parent-chain schedule");
  check(f.disk.writes == 2 && f.disk.flushes == 2 &&
            f.disk.bytes[0].size() == 8192,
        "reuse R2 single-write/Flush fixed-size evidence");
  check(r.artifact_read_calls == 768 && r.reserved[s::hash_reads] == 768,
        "each frozen artifact hashed once, <=256 reads");
  const auto before = r.reserved;
  check(!f.preparation.run_offline() && before == r.reserved &&
            f.ops.creates == 1,
        "second entry burns no fresh budget and never retries");
  check(!f.preparation.close_root_once("OTHER") &&
            !f.preparation.close_evidence_once("OTHER") &&
            f.ops.root_closes == 0 && f.ops.evidence_closes == 0,
        "wrong Owner cannot close");
  check(
      f.preparation.close_root_once(f.q.frozen.manifest.pin_owner) &&
          f.preparation.close_evidence_once(f.q.frozen.manifest.evidence_owner),
      "named Owners close once");
  check(!f.preparation.close_root_once(f.q.frozen.manifest.pin_owner) &&
            !f.preparation.close_evidence_once(
                f.q.frozen.manifest.evidence_owner) &&
            f.ops.root_closes == 1 && f.ops.evidence_closes == 1,
        "no double release");
  check(r.reserved == f.q.budget,
        "successful flow and both closes consume source ceiling exactly");
  for (const auto &bytes : f.disk.bytes) {
    const std::string text(bytes.begin(), bytes.end());
    check(text.find("FAKE-SID") == std::string::npos &&
              text.find("C:\\SYNTHETIC") == std::string::npos,
          "serialized evidence excludes raw SID/path");
  }
}
void rejection_and_drift() {
  for (auto creation :
       {s::Creation::exists, s::Creation::denied, s::Creation::unknown}) {
    S1Fixture f;
    f.ops.creation = creation;
    check(!f.preparation.run_offline() && f.ops.creates == 1 &&
              f.ops.roots == 0 && f.ops.handoffs == 0,
          "existing/denied/uncertain target rejects without reopen or "
          "inspection");
    check(!f.preparation.run_offline() && f.ops.creates == 1,
          "no retry for existing target");
    check(!f.preparation.result().root.object.valid(),
          "failure does not invent new ID");
    check(f.preparation.result().state == (creation == s::Creation::unknown
                                               ? s::State::unknown
                                               : s::State::rejected),
          "only an uncertain create retains UNKNOWN");
  }
  for (unsigned kind = 0; kind < 10; ++kind)
    for (unsigned pass = 0; pass < 4; ++pass) {
      S1Fixture f;
      f.ops.drift_kind = kind;
      f.ops.drift_call = pass * 2 + 1;
      check(!f.preparation.run_offline() && f.ops.handoffs == 0,
            "all parent drift/type/ACL failures reject");
      check(f.ops.creates == (pass < 2 ? 0u : 1u),
            "recheck immediately before exclusive create");
      if (pass >= 2)
        check(f.preparation.result().state == s::State::unknown &&
                  f.ops.root_closes == 0,
              "post-create failure retains UNKNOWN and owned root");
    }
  for (unsigned root_fail : {1u, 2u}) {
    S1Fixture f;
    f.ops.root_fail = root_fail;
    check(!f.preparation.run_offline() &&
              f.preparation.result().state == s::State::unknown &&
              f.ops.creates == 1 && f.ops.root_closes == 0,
          "failed root observation keeps UNKNOWN without repair");
    check(f.preparation.result().last.stage == r::Stage::kRecoveryRequired &&
              f.preparation.result().last.recovery_required &&
              f.preparation.result().last.first_failure ==
                  r::Failure::kMeasurement,
          "UNKNOWN STOP persists its measurement class as recovery-required");
  }
  S1Fixture changed;
  changed.ops.root_identity_drift = true;
  check(!changed.preparation.run_offline() &&
            changed.preparation.result().state == s::State::unknown &&
            changed.ops.handoffs == 0,
        "new root File ID drift never reaches Pin handoff");
  for (unsigned kind = 0; kind < 5; ++kind) {
    S1Fixture f;
    if (kind == 0)
      ++f.ops.actual.object.volume_serial;
    if (kind == 1)
      f.ops.actual.object.file_id = {};
    if (kind == 2)
      f.ops.actual.owner = "WRONG-ROOT-OWNER";
    if (kind == 3)
      f.ops.actual.security_sha256 = std::string(64, '0');
    if (kind == 4)
      ++f.ops.actual.parent.file_id[0];
    check(
        !f.preparation.run_offline() &&
            f.preparation.result().state == s::State::unknown &&
            f.preparation.result().stopped && f.ops.root_closes == 0,
        "root Volume/File ID/Owner/DACL/parent mismatch retains STOP UNKNOWN");
  }
  S1Fixture a;
  a.ops.bad_artifact = true;
  check(!a.preparation.run_offline() && a.ops.creates == 0,
        "artifact hash drift prevents root create");
  for (uint32_t reads : {0u, 257u}) {
    S1Fixture r;
    r.ops.forced_reads = reads;
    check(!r.preparation.run_offline() &&
              r.preparation.result().failure == s::Failure::artifact &&
              r.ops.creates == 0,
          "missing or excessive artifact reads reject before create");
  }
  S1Fixture i;
  i.ops.bad_identity = true;
  check(!i.preparation.run_offline() && i.ops.creates == 0,
        "Token identity failure prevents create");
}
void metadata_digest_binding() {
  auto q = request();
  check(s::metadata_digest(q.parents[0].object) == q.parents[0].bytes_sha256,
        "approved parent Pin carries the digest of its own Volume/File ID");
  auto other = q.parents[0].object;
  ++other.file_id[0];
  check(s::metadata_digest(other) != q.parents[0].bytes_sha256,
        "metadata-only digest binds the actual File ID bytes");
  auto wrong_parent = q;
  wrong_parent.parents[1].bytes_sha256 = std::string(64, '0');
  check(!wrong_parent.valid(),
        "formatted but unrelated parent digest rejects the request");
  auto wrong_evidence = q;
  wrong_evidence.evidence_parents[2].bytes_sha256 =
      s::metadata_digest(wrong_evidence.parents[0].object);
  check(!wrong_evidence.valid(),
        "a digest copied from another approved object rejects the request");
  S1Fixture d;
  d.ops.wrong_root_digest = true;
  check(!d.preparation.run_offline() &&
            d.preparation.result().failure == s::Failure::root &&
            d.preparation.result().state == s::State::unknown &&
            d.ops.handoffs == 0 && d.ops.root_closes == 0 &&
            !d.preparation.result().root.object.valid(),
        "unchanged root File ID with a non-derivable digest never reaches "
        "handoff");
}
void evidence_budget_and_gate() {
  for (unsigned fail = 1; fail <= 2; ++fail)
    for (unsigned kind = 0; kind < 4; ++kind) {
      S1Fixture f;
      if (kind == 0)
        f.disk.fail_write = fail;
      if (kind == 1)
        f.disk.fail_flush = fail;
      if (kind == 2)
        f.S1Sink.lost_ack = fail;
      if (kind == 3)
        f.disk.short_write = true;
      check(!f.preparation.run_offline() &&
                f.preparation.result().state == s::State::unknown &&
                !f.preparation.result().evidence_preserved,
            "write/Flush/short-write/lost-ACK never PASS");
      check(f.S1Sink.calls <= 2 && f.ops.root_closes == 0,
            "evidence stream never retries or cleans root");
    }
  for (unsigned kind = 0; kind < 2; ++kind) {
    S1Fixture f;
    f.ops.bad_handoff = kind == 0;
    f.ops.throw_handoff = kind == 1;
    check(!f.preparation.run_offline() &&
              f.preparation.result().state == s::State::unknown &&
              f.ops.handoffs == 1 && f.ops.root_closes == 0,
          "uncertain Pin ACK retains UNKNOWN");
    check(!f.preparation.close_root_once(f.q.frozen.manifest.pin_owner),
          "UNKNOWN root is not auto-released");
    check(
        !f.preparation.close_evidence_once(f.q.frozen.manifest.evidence_owner),
        "UNKNOWN evidence is not auto-released");
  }
  for (size_t counter = 0; counter < s::counter_count; ++counter) {
    auto q = request();
    q.budget[counter] = 1;
    Ops ops(q);
    Disk disk;
    S1Sink S1Sink(disk, q);
    s::Preparation p(q, ops, S1Sink);
    const bool passed = p.run_offline();
    // One-attempt operations legitimately need exactly one unit.
    const bool singleton = q.budget[counter] == s::ceiling(2, 3, 3)[counter];
    check(passed == singleton,
          "every non-singleton exhausted budget prevents PASS");
    for (size_t i = 0; i < s::counter_count; ++i)
      check(p.result().reserved[i] <= q.budget[i],
            "no operation reserved beyond approved budget");
  }
  {
    auto q = request();
    q.budget[s::os_calls] = s::ceiling(2, 3, 3)[s::os_calls] + 1;
    Ops ops(q);
    Disk disk;
    S1Sink sink(disk, q);
    s::Preparation p(q, ops, sink);
    check(!p.run_offline() && p.result().failure == s::Failure::target &&
              ops.identities == 0,
          "budget above the source ceiling never enters identity");
  }
  {
    auto q = request();
    q.budget[s::security_sets] = 1; // evidence opens; create cannot reserve
    Ops ops(q);
    Disk disk;
    S1Sink sink(disk, q);
    s::Preparation p(q, ops, sink);
    check(!p.run_offline() && p.result().failure == s::Failure::budget &&
              p.result().state == s::State::rejected &&
              p.result().last.stage == r::Stage::kFinal &&
              !p.result().last.recovery_required &&
              p.result().last.first_failure == r::Failure::kBudget,
          "rejected STOP persists its budget class as a terminal record");
  }
  for (auto source : {r::Origin::kWindowsApi, r::Origin::kUnavailable,
                      r::Origin::kIndependentBuild}) {
    S1Fixture f;
    f.ops.source = source;
    check(!f.preparation.run_offline() &&
              f.preparation.result().runtime_denied && f.ops.identities == 0 &&
              f.ops.creates == 0,
          "non-Fake cannot enter through offline entry");
  }
  wchar_t arg[] = L"--enable-l1";
  wchar_t *argv[] = {arg};
  check(!s::windows_runtime_allowed() &&
            s::windows_process_entry(1, argv) == 10 &&
            s::windows_process_entry(0, nullptr) == 10,
        "real entry refuses every argument, no opt-in");
  S1Fixture c;
  c.ops.close_failure = true;
  check(c.preparation.run_offline() &&
            !c.preparation.close_root_once(c.q.frozen.manifest.pin_owner) &&
            c.preparation.result().state == s::State::unknown &&
            !c.preparation.close_root_once(c.q.frozen.manifest.pin_owner) &&
            c.ops.root_closes == 1,
        "unknown CloseHandle is not repeated");
}
unsigned temporary_closes = 0;
bool close_ok(uintptr_t) noexcept {
  ++temporary_closes;
  return true;
}
bool close_unknown(uintptr_t) noexcept {
  ++temporary_closes;
  return false;
}
void temporary_ownership() {
  static_assert(!std::is_copy_constructible_v<TemporaryHandle>);
  static_assert(!std::is_move_constructible_v<TemporaryHandle>);
  using O = TemporaryOwner;
  temporary_closes = 0;
  {
    TemporaryHandle h(O::token_reader, 1, close_ok);
    check(!h.close_as(O::token_validator) && temporary_closes == 0,
          "other temporary Owner cannot release");
    check(h.close_as(O::token_reader) && !h.close_as(O::token_reader),
          "temporary Owner closes once");
  }
  check(temporary_closes == 1, "destructor does not double-close");
  {
    TemporaryHandle h(O::token_validator, 2, close_unknown);
    check(!h.close_as(O::token_validator) && h.unknown(),
          "close failure remains UNKNOWN");
  }
  check(temporary_closes == 2, "UNKNOWN close never retries during unwind");
  try {
    TemporaryHandle h(O::token_reader, 3, close_ok);
    throw 1;
  } catch (...) {
  }
  check(temporary_closes == 3,
        "exception unwinding closes acquired temporary once by its Owner");
  {
    TemporaryHandle h(O::image_reader, 4, close_unknown);
    check(!h.close_as(O::token_reader) && temporary_closes == 3,
          "Token Owner cannot settle temporary image HANDLE");
    check(!h.close_as(O::image_reader) && h.unknown(),
          "image Owner close failure is UNKNOWN");
  }
  check(temporary_closes == 4, "temporary image close never retries on unwind");
}
} // namespace
int main() {
  success_and_ownership();
  rejection_and_drift();
  metadata_digest_binding();
  evidence_budget_and_gate();
  temporary_ownership();
  std::cout << "PASS: " << checks
            << " S1 root preparation/ownership/budget assertions; OFFLINE/FAKE "
               "only\n";
}
