#include "diagnostics/l1_s1_root.h"
#include "diagnostics/l1_temporary_handle.h"
#include "tests/l1_r1_fixture.h"
#include <type_traits>
namespace s = shiroha_l1_crypto::s1;
namespace z = shiroha_l1_crypto::r2;
namespace {
s::Request request() {
  s::Request q;
  q.frozen = frozen();
  q.limits.custodian_sha256 = std::string(64, '7');
  q.limits.channel_sha256 = std::string(64, '8');
  q.limits.process = {z::ResourceLimit{2048, 4096, 10},
                      z::ResourceLimit{3072, 6144, 16},
                      z::ResourceLimit{4096, 8192, 20}};
  q.limits.polls = 128;
  q.limits.poll_ms = 10;
  q.limits.ui_events = 64;
  q.limits.approval_ms = 30000;
  q.limits.handoff_ms = 15000;
  auto &f = q.frozen;
  f.manifest.pins[0].bytes_sha256 = f.manifest.build.controller;
  f.manifest.pins[1].bytes_sha256 = q.limits.custodian_sha256;
  f.manifest.pins[2].bytes_sha256 = f.manifest.build.worker;
  f.manifest.r2_sha256 = q.limits.hash();
  f.target.scope.wiring_manifest_sha256 = f.manifest.hash();
  f.target.grant.evidence_scope_id = f.target.scope.hash();
  for (uint8_t i = 0; i < 3; ++i) {
    r::Pin p;
    p.id = "ANCESTOR-" + std::to_string(i);
    p.owner = f.manifest.pin_owner;
    p.object.volume_serial = 9;
    p.object.file_id[0] = uint8_t(40 + i);
    p.parent = i ? q.evidence_parents.back().object : p.object;
    p.security_sha256 = std::string(64, '9');
    p.bytes_sha256 = s::metadata_digest(p.object);
    q.evidence_parents.push_back(p);
    if (i < 2)
      q.parents.push_back(p);
  }
  q.root_id = "NEW-ROOT";
  q.root_security_sha256 = std::string(64, '6');
  q.evidence_directory = "C:\\SYNTHETIC\\EVIDENCE";
  q.budget = s::ceiling(q.parents.size(), f.manifest.pins.size(),
                        q.evidence_parents.size());
  check(q.valid(), "separately supplied synthetic preparation request");
  return q;
}
struct Disk final : z::PersistencePort {
  uint32_t writes = 0, flushes = 0, inspects = 0, fail_write = 0,
           fail_flush = 0;
  bool short_write = false;
  std::vector<std::vector<uint8_t>> bytes;
  r::Origin origin() const noexcept override { return r::Origin::kFake; }
  bool inspect_destination() override {
    ++inspects;
    return true;
  }
  z::WriteStatus write(const uint8_t *p, size_t n, size_t &done) override {
    ++writes;
    if (writes == fail_write)
      return z::WriteStatus::unknown;
    done = short_write ? n - 1 : n;
    bytes.emplace_back(p, p + n);
    return z::WriteStatus::ok;
  }
  z::WriteStatus flush() override {
    return ++flushes == fail_flush ? z::WriteStatus::unknown
                                   : z::WriteStatus::ok;
  }
};
struct S1Sink final : r::EvidenceSink {
  z::PersistentEvidence persisted;
  uint32_t calls = 0, lost_ack = 0;
  S1Sink(Disk &d, const s::Request &q)
      : persisted(d, q.frozen.target.grant.batch_id, q.frozen.hash(),
                  q.frozen.manifest.evidence_owner, 2) {}
  r::SinkReceipt preserve(const r::Record &r) override {
    ++calls;
    auto ack = persisted.preserve(r);
    if (calls == lost_ack)
      ack.record_sha256 = std::string(64, '0');
    return ack;
  }
};
struct Ops final : s::Operations {
  s::Request q;
  r::Origin source = r::Origin::kFake;
  unsigned identities = 0, parent_calls = 0, artifacts = 0, creates = 0,
           roots = 0, opens = 0, handoffs = 0, root_closes = 0,
           evidence_closes = 0;
  unsigned drift_call = 0, drift_kind = 0, root_fail = 0;
  uint32_t forced_reads = 256;
  bool bad_identity = false, bad_artifact = false, bad_handoff = false,
       throw_handoff = false, close_failure = false, open_failure = false,
       root_identity_drift = false, wrong_root_digest = false;
  s::Creation creation = s::Creation::created;
  r::Pin actual;
  explicit Ops(s::Request r) : q(std::move(r)) {
    actual.id = q.root_id;
    actual.owner = q.frozen.manifest.pin_owner;
    actual.object.volume_serial = 9;
    actual.object.file_id[0] = 80;
    actual.parent = q.parents.back().object;
    actual.security_sha256 = q.root_security_sha256;
    actual.bytes_sha256 = s::metadata_digest(actual.object);
  }
  r::Origin origin() const noexcept override { return source; }
  s::Runtime identity() override {
    ++identities;
    s::Runtime m;
    auto &f = m.facts;
    f.origin = source;
    f.sid = q.frozen.target.sid;
    f.os = q.frozen.manifest.os_sha256;
    f.account = q.frozen.target.grant.account_identity_sha256;
    f.primary_medium = f.non_elevated = !bad_identity;
    f.pid = 5;
    f.creation_time = 55;
    m.device_sha256 = q.frozen.manifest.device_sha256;
    return m;
  }
  s::Observation parent(size_t i) override {
    ++parent_calls;
    s::Observation o{q.parents[i], true, true, false, false, true};
    if (parent_calls == drift_call) {
      switch (drift_kind) {
      case 0:
        ++o.pin.object.volume_serial;
        o.pin.bytes_sha256 = s::metadata_digest(o.pin.object);
        break;
      case 1:
        ++o.pin.object.file_id[0];
        o.pin.bytes_sha256 = s::metadata_digest(o.pin.object);
        break;
      case 2:
        o.pin.owner = "OTHER-OWNER";
        break;
      case 3:
        o.pin.security_sha256 = std::string(64, '0');
        break;
      case 4:
        o.reparse = true;
        break;
      case 5:
        o.directory = false;
        break;
      case 6:
        o.c_ntfs = false;
        break;
      case 7:
        o.exact_path = false;
        break;
      case 8:
        o.delete_pending = true;
        break;
      default:
        return {};
      }
    }
    return o;
  }
  bool artifact(size_t i, r::Pin &p, uint32_t &reads) override {
    ++artifacts;
    p = q.frozen.manifest.pins[i];
    reads = forced_reads;
    if (bad_artifact)
      p.bytes_sha256 = std::string(64, '0');
    return true;
  }
  s::Creation create_root() override {
    ++creates;
    return creation;
  }
  s::Observation root() override {
    ++roots;
    if (roots == root_fail)
      return {};
    if (roots == 2 && root_identity_drift) {
      ++actual.object.file_id[0];
      actual.bytes_sha256 = s::metadata_digest(actual.object);
    }
    r::Pin p = actual;
    if (wrong_root_digest)
      p.bytes_sha256 = std::string(64, '0');
    return {p, true, true, false, false, true};
  }
  bool open_evidence() override {
    ++opens;
    return !open_failure;
  }
  s::Handoff handoff(const r::Pin &p, const std::string &h) override {
    ++handoffs;
    if (throw_handoff)
      throw std::runtime_error("synthetic");
    return {bad_handoff ? r::IoStatus::kUnknown : r::IoStatus::kOk, p.owner, h,
            s::pin_hash(p)};
  }
  bool close_root() override {
    ++root_closes;
    return !close_failure;
  }
  bool close_evidence() override {
    ++evidence_closes;
    return !close_failure;
  }
};
struct S1Fixture {
  s::Request q = request();
  Ops ops{q};
  Disk disk;
  S1Sink S1Sink{disk, q};
  s::Preparation preparation{q, ops, S1Sink};
};
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
    check(f.preparation.result().state ==
              (creation == s::Creation::unknown ? s::State::unknown
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
    check(!f.preparation.close_evidence_once(f.q.frozen.manifest.evidence_owner),
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
