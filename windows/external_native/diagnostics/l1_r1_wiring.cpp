#include "diagnostics/l1_r1_wiring.h"

namespace shiroha_l1_crypto {
namespace r1 {
namespace {
void pin_hash(CanonicalHashBuilder &b, const ObjectIdentityPin &p) {
  b.put_u64_le(p.volume_serial);
  b.put_bytes(p.file_id.data(), p.file_id.size());
}
void counts_hash(CanonicalHashBuilder &b, const CallCounts &c) {
  for (auto n : {c.attempted, c.returned, c.accepted, c.settled, c.unknown,
                 c.returned_failure})
    b.put_u32_le(n);
}
void sample_hash(CanonicalHashBuilder &b, const ResourceSample &s) {
  b.put_u64_le(s.observed_at_ms);
  b.put_u64_le(s.peak_working_set);
  b.put_u64_le(s.peak_commit);
  b.put_u32_le(s.handles);
  b.put_u32_le(s.completed_calls);
}
std::string process_hash(const ProcessIdentity &p) {
  CanonicalHashBuilder b;
  b.put_str("SHIROHA_L1_R1_PROCESS_V1");
  b.put_u32_le(p.pid);
  b.put_u64_le(p.creation_time);
  b.put_str(p.image_sha256);
  b.put_str(p.account_sha256);
  b.put_str(p.target_sha256);
  b.put_str(p.owner);
  b.put_bool(p.primary_medium);
  b.put_bool(p.non_elevated);
  return b.finalize_hex();
}
} // namespace
std::string ProcessIdentity::hash() const { return process_hash(*this); }
bool Pin::operator==(const Pin &p) const {
  return id == p.id && owner == p.owner &&
         security_sha256 == p.security_sha256 &&
         bytes_sha256 == p.bytes_sha256 && object == p.object &&
         parent == p.parent;
}
bool BuildEvidence::operator==(const BuildEvidence &p) const {
  return origin == p.origin && source == p.source && base == p.base &&
         toolchain == p.toolchain && controller == p.controller &&
         worker == p.worker && dependencies == p.dependencies;
}
bool Manifest::valid() const {
  if (!r2_sha256.empty() && !hex_digest(r2_sha256, 64))
    return false;
  if (!hex_digest(device_sha256, 64) || !hex_digest(os_sha256, 64) ||
      !safe_id(pin_owner) || !safe_id(custody_owner) ||
      !safe_id(evidence_owner) || !max_pumps || max_pumps > 4096 ||
      pins.size() < 2 || pins.size() > 146 || !hex_digest(build.source, 40) ||
      !hex_digest(build.base, 40))
    return false;
  for (auto p : {&build.toolchain, &build.controller, &build.worker,
                 &build.dependencies})
    if (!hex_digest(*p, 64))
      return false;
  for (size_t i = 0; i < pins.size(); ++i) {
    const auto &p = pins[i];
    if (!safe_id(p.id) || p.owner != pin_owner || !p.object.valid() ||
        !p.parent.valid() || !hex_digest(p.security_sha256, 64) ||
        !hex_digest(p.bytes_sha256, 64))
      return false;
    for (size_t j = 0; j < i; ++j)
      if (pins[j].id == p.id || pins[j].object == p.object)
        return false;
  }
  return true;
}
std::string Manifest::hash() const {
  CanonicalHashBuilder b;
  b.put_str("SHIROHA_L1_R1_MANIFEST_V1");
  for (auto p : {&device_sha256, &os_sha256, &pin_owner, &custody_owner,
                 &evidence_owner, &build.source, &build.base, &build.toolchain,
                 &build.controller, &build.worker, &build.dependencies})
    b.put_str(*p);
  b.put_u32_le(uint32_t(build.origin));
  b.put_u32_le(max_pumps);
  b.put_u32_le(uint32_t(pins.size()));
  for (const auto &p : pins) {
    b.put_str(p.id);
    b.put_str(p.owner);
    b.put_str(p.security_sha256);
    b.put_str(p.bytes_sha256);
    pin_hash(b, p.object);
    pin_hash(b, p.parent);
  }
  if (!r2_sha256.empty()) {
    b.put_str("SHIROHA_L1_R2_POLICY_V1");
    b.put_str(r2_sha256);
  }
  return b.finalize_hex();
}
bool Frozen::valid() const {
  const auto &g = target.grant;
  const auto &b = manifest.build;
  return target.valid() && g.is_admission_only() && manifest.valid() &&
         target.scope.wiring_manifest_sha256 == manifest.hash() &&
         b.source == g.source_sha && b.base == g.base_sha &&
         b.toolchain == g.toolchain_manifest_sha256 &&
         b.worker == g.exe_sha256 &&
         b.controller == target.scope.controller_exe_sha256 &&
         b.dependencies == g.dependency_manifest_sha256 &&
         manifest.evidence_owner == g.evidence_owner;
}
std::string Frozen::hash() const {
  std::string h;
  if (!valid() || !compute_target_binding_sha256(target.grant, target.sid, h))
    return {};
  return h;
}
bool Frozen::matches(const Measurement &m) const {
  // Only in-memory Fake implementations are admitted by THIS composition.
  // WindowsApi/IndependentBuild origins cannot be relabeled LOCAL-L1 here.
  return valid() && m.origin == Origin::kFake &&
         m.build.origin == Origin::kFake &&
         m.device_sha256 == manifest.device_sha256 &&
         m.os_sha256 == manifest.os_sha256 &&
         m.account_sha256 == target.grant.account_identity_sha256 &&
         m.token_sid == target.sid && m.primary_medium && m.non_elevated &&
         m.minimal_privileges && m.build == manifest.build &&
         m.pins == manifest.pins;
}
std::string Record::hash() const {
  if (!safe_id(batch) || !hex_digest(target, 64) || !hex_digest(manifest, 64) ||
      (!previous.empty() && !hex_digest(previous, 64)) || !sequence ||
      !safe_id(reviewer) || !safe_id(verifier) ||
      !hex_digest(review_sha256, 64) || !hex_digest(verification_sha256, 64) ||
      sample_count > 18 ||
      (!process_identity_sha256.empty() &&
       !hex_digest(process_identity_sha256, 64)))
    return {};
  CanonicalHashBuilder b;
  b.put_str("SHIROHA_L1_R1_EVIDENCE_V1");
  b.put_str("OFFLINE");
  b.put_str("L1-ADMISSION");
  for (auto p :
       {&batch, &target, &manifest, &previous, &reviewer, &verifier,
        &review_sha256, &verification_sha256, &process_identity_sha256})
    b.put_str(*p);
  b.put_u32_le(sequence);
  b.put_u32_le(uint32_t(stage));
  b.put_u32_le(uint32_t(first_failure));
  b.put_u32_le(pid);
  b.put_u64_le(creation_time);
  b.put_u64_le(utc_ms);
  b.put_u64_le(mono_ms);
  b.put_u64_le(launch_attempt_ms);
  b.put_u32_le(uint32_t(first_stop));
  for (const auto &c : abi)
    counts_hash(b, c);
  for (const auto &c : native)
    counts_hash(b, c);
  b.put_u32_le(sample_count);
  for (const auto &s : samples)
    sample_hash(b, s);
  sample_hash(b, controller_peak);
  for (bool f :
       {approved, consumed, created, resumed, custody_accepted,
        custody_acknowledged, exited, handles_closed, recovery_required,
        creation_unknown, deadline_exceeded, ipc_complete})
    b.put_bool(f);
  b.put_u32_le(uint32_t(security));
  b.put_u32_le(uint32_t(stability));
  return b.finalize_hex();
}
Composition::Composition(Frozen f, e4::GrantIo &io, IdentityPort &id,
                         CustodyPort &c, EvidenceSink &s)
    : frozen_(std::move(f)), io_(io), identity_(id), custody_(c), sink_(s),
      controller_(frozen_.target, *this, *this) {}
void Composition::fail(Failure f) noexcept {
  if (result_.first_failure == Failure::kNone)
    result_.first_failure = f;
  result_.last.first_failure = result_.first_failure;
  offline_ready_ = false;
}
bool Composition::save(Stage s) {
  if (result_.terminal || sink_failed_)
    return false;
  auto &r = result_.last;
  if (++result_.writes_attempted > frozen_.manifest.max_pumps + 32) {
    sink_failed_ = true;
    fail(Failure::kBudget);
    return false;
  }
  r.stage = s;
  r.sequence = result_.writes_attempted;
  r.batch = frozen_.target.grant.batch_id;
  r.target = frozen_.hash();
  r.manifest = frozen_.manifest.hash();
  r.reviewer = frozen_.target.grant.reviewer_id;
  r.verifier = frozen_.target.grant.verifier_id;
  r.review_sha256 = frozen_.target.grant.review_sha256;
  r.verification_sha256 = frozen_.target.grant.verification_sha256;
  const auto hash = r.hash();
  SinkReceipt ack;
  try {
    if (!hash.empty())
      ack = sink_.preserve(r);
  } catch (...) {
  }
  if (hash.empty() || ack.origin != Origin::kFake ||
      ack.status != IoStatus::kOk || ack.sequence != r.sequence ||
      ack.record_sha256 != hash) {
    sink_failed_ = true;
    result_.evidence_preserved = false;
    fail(Failure::kEvidence);
    return false;
  }
  r.previous = hash;
  result_.evidence_preserved = true;
  return true;
}
bool Composition::receipt_ok(const CustodyReceipt &r, bool handles) const {
  return r.origin == Origin::kFake && r.status == IoStatus::kOk &&
         r.creator_is_independent &&
         (!handles || (r.owns_process_and_thread &&
                       r.process_identity_sha256 == process_.hash())) &&
         r.owner == frozen_.manifest.custody_owner &&
         r.target_sha256 == frozen_.hash() &&
         hex_digest(r.external_record_sha256, 64);
}
bool Composition::begin() noexcept try {
  if (attempted_)
    return false;
  attempted_ = true;
  if (!frozen_.valid()) {
    fail(Failure::kTarget);
    finish();
    return false;
  }
  if (!save(Stage::kControllerStarted)) {
    finish();
    return false;
  }
  if (!frozen_.matches(identity_.measure()) || !save(Stage::kMeasured)) {
    fail(Failure::kMeasurement);
    finish();
    return false;
  }
  if (!save(Stage::kCreateIntent) ||
      !receipt_ok(custody_.accept_intent(frozen_), false)) {
    fail(Failure::kCustody);
    finish();
    return false;
  }
  result_.last.custody_accepted = true;
  if (!save(Stage::kCustodyAccepted)) {
    finish();
    return false;
  }
  offline_ready_ = true;
  const bool running = controller_.begin();
  capture();
  if (!running)
    finish();
  return running;
} catch (...) {
  fail(Failure::kCustody);
  finish();
  return false;
}
bool Composition::pump() noexcept try {
  if (!attempted_ || result_.terminal || lost_)
    return false;
  if (++result_.pumps > frozen_.manifest.max_pumps) {
    fail(Failure::kBudget);
    controller_lost();
    return false;
  }
  const bool running = controller_.pump();
  capture();
  if (running && !save(Stage::kIpc)) {
    // The failed sink closes Grant inspection. Let the EXISTING Controller
    // stop and perform its legal owner settlement; do not invent a new stop
    // loop.
    controller_.pump();
    finish();
    return false;
  }
  if (!running)
    finish();
  return running;
} catch (...) {
  fail(Failure::kProtocol);
  controller_lost();
  return false;
}
void Composition::controller_lost() noexcept {
  if (result_.terminal || lost_)
    return;
  lost_ = true;
  fail(Failure::kControllerLost);
  result_.last.recovery_required = true;
  custody_.controller_lost(); // no close, Resume, create or recovery action
  finish();
}
bool Composition::inspect_target(const e5::FixedTarget &t) {
  if (++measurements_ > 4 ||
      t.grant.identity() != frozen_.target.grant.identity() ||
      t.sid != frozen_.target.sid || !frozen_.matches(identity_.measure())) {
    fail(Failure::kMeasurement);
    return false;
  }
  return true;
}
bool Composition::approve(const e4::ApprovalPromptModel &p,
                          e4::ApprovalUiResponse &r) {
  if (!custody_.approve(p, r))
    return false;
  e4::ApprovalPromptModel base;
  if (!e4::prompt(frozen_.target.grant, frozen_.target.sid, base) ||
      !e4::confirm(base, r, frozen_.target.grant, frozen_.target.sid))
    return false;
  result_.last.approved = true;
  return save(Stage::kApproval);
}
e4::ClockReading Composition::read_clock() {
  if (++clocks_ > 4 * frozen_.manifest.max_pumps + 16) {
    fail(Failure::kBudget);
    return {};
  }
  auto r = custody_.read_clock();
  if (r.valid) {
    result_.last.utc_ms = r.utc;
    result_.last.mono_ms = r.mono;
  }
  return r;
}
e4::WorkerStart Composition::start_suspended(const GrantTarget &t,
                                             const e4::Digest &d,
                                             e4::ClockReading launch) {
  auto approved = frozen_.target.grant;
  approved.user_approved = true;
  if (create_attempted_ || !result_.last.custody_accepted ||
      !result_.last.consumed || t.identity() != approved.identity() ||
      encode_hex_bytes(d.data(), d.size()) != frozen_.hash() ||
      !inspect_target(frozen_.target))
    return {};
  create_attempted_ = true; // before any effect or ambiguous return
  struct Steps final : e4::LaunchSteps {
    Composition &c;
    e4::WorkerStart created{};
    e4::ClockReading launch;
    e4::ClockValidator clock;
    Steps(Composition &v, e4::ClockReading r) : c(v), launch(r) {
      clock.accept(r);
    }
    bool timely() {
      auto now = c.read_clock();
      const bool ok = clock.accept(now) &&
                      e4::window(c.frozen_.target.grant, now) &&
                      now.mono >= launch.mono && now.mono - launch.mono < 30000;
      if (!ok)
        c.fail(Failure::kDeadline);
      return ok;
    }
    e4::WorkerStart create() override {
      if (!c.save(Stage::kCreateAttempt) || !timely())
        return {};
      created = c.custody_.create();
      c.result_.last.created = created.created;
      return created;
    }
    bool token() override {
      if (!timely())
        return false;
      c.process_ = c.custody_.process_identity();
      const auto &p = c.process_;
      if (p.pid != created.pid || !p.pid || !p.creation_time ||
          !p.primary_medium || !p.non_elevated ||
          p.owner != c.frozen_.manifest.custody_owner ||
          p.target_sha256 != c.frozen_.hash() ||
          p.image_sha256 != c.frozen_.target.grant.exe_sha256 ||
          p.account_sha256 != c.frozen_.target.grant.account_identity_sha256 ||
          !c.custody_.token())
        return false;
      c.result_.last.pid = p.pid;
      c.result_.last.creation_time = p.creation_time;
      c.result_.last.process_identity_sha256 = process_hash(p);
      return c.save(Stage::kProcessIdentity);
    }
    bool image() override { return timely() && c.custody_.image(); }
    bool dependencies() override {
      return timely() && c.custody_.dependencies();
    }
    bool handles() override {
      if (!timely() || !c.custody_.handles() ||
          !c.receipt_ok(c.custody_.acknowledge_identity(c.process_), true))
        return false;
      c.result_.last.custody_acknowledged = true;
      return c.save(Stage::kCustodyAcknowledged);
    }
    bool resume(bool &known) override {
      if (!c.save(Stage::kResumeAttempt) || !timely())
        return false;
      const bool ok = c.custody_.resume(known);
      c.result_.last.resumed = ok && known;
      return c.save(Stage::kResumed) && ok;
    }
    bool hello() override { return timely() && c.custody_.hello() && timely(); }
  } steps(*this, launch);
  return e4::launch_once(steps);
}
e5::Observation Composition::observe() {
  if (++observations_ > 2 * frozen_.manifest.max_pumps + 16) {
    fail(Failure::kBudget);
    return {};
  }
  auto o = custody_.observe();
  if (o.healthy && o.exited)
    exit_observed_ = true;
  return o;
}
bool Composition::next(e4::Frame &f, bool &available) {
  if (++nexts_ > frozen_.manifest.max_pumps) {
    fail(Failure::kBudget);
    return false;
  }
  return custody_.next(f, available);
}
bool Composition::send(const e4::Frame &f) {
  const bool stop = e4::get(f.data() + 6, 2) == unsigned(e4::Message::stop);
  if (++sends_ > 3 ||
      (e4::get(f.data() + 6, 2) == unsigned(e4::Message::admission) &&
       (sink_failed_ || !result_.last.custody_acknowledged)))
    return false;
  if (!save(Stage::kIpc) && !stop)
    return false;
  return custody_.send(f);
}
bool Composition::close_observed_exit() {
  if (!exit_observed_)
    return false;
  result_.last.exited = true;
  // Evidence failure cannot suppress an owner's already-authorized single
  // close.
  save(Stage::kExitObserved);
  result_.last.handles_closed = custody_.close_observed_exit();
  save(Stage::kHandlesSettled);
  return result_.last.handles_closed;
}
bool Composition::close_owned_io() {
  const bool io = custody_.close_owned_io();
  if (create_attempted_ && (!exit_observed_ || !result_.last.handles_closed))
    return false; // including creation UNKNOWN
  if (pins_close_attempted_)
    return false;
  pins_close_attempted_ = true;
  const bool pins = identity_.close_borrowed_pins_once();
  return io && pins;
}
void Composition::handoff(const std::string &, uint32_t) noexcept {
  fail(Failure::kCustody);
  result_.last.recovery_required = true;
  custody_.controller_lost();
}
bool Composition::principal(const std::wstring &sid) {
  return sid == frozen_.target.sid && io_.principal(sid);
}
e4::IoResult Composition::issue_new(const e4::Receipt &r, BatchObjectPins &p) {
  if (!save(Stage::kIssueIntent))
    return e4::IoResult::unknown;
  auto s = io_.issue_new(r, p);
  return s == e4::IoResult::ok && save(Stage::kIssued) ? s
                                                       : e4::IoResult::unknown;
}
bool Composition::inspect(const BatchObjectPins &p) {
  if (++record_inspections_ > 3 * frozen_.manifest.max_pumps + 16) {
    fail(Failure::kBudget);
    return false;
  }
  return !sink_failed_ && io_.inspect(p);
}
e4::IoResult Composition::request_new(const e4::Journal &j) {
  if (!save(Stage::kRequestIntent))
    return e4::IoResult::unknown;
  auto s = io_.request_new(j);
  return s == e4::IoResult::ok && save(Stage::kRequested)
             ? s
             : e4::IoResult::unknown;
}
e4::IoResult Composition::burn_issued() {
  if (!save(Stage::kBurnIntent))
    return e4::IoResult::unknown;
  auto s = io_.burn_issued();
  result_.last.consumed = s == e4::IoResult::ok;
  return s == e4::IoResult::ok && save(Stage::kConsumed)
             ? s
             : e4::IoResult::unknown;
}
e4::IoResult Composition::update_request(const e4::Journal &j) {
  if (!save(Stage::kJournalIntent))
    return e4::IoResult::unknown;
  auto s = io_.update_request(j);
  return s == e4::IoResult::ok && save(Stage::kJournalUpdated)
             ? s
             : e4::IoResult::unknown;
}
void Composition::capture() {
  result_.core = controller_.evidence();
  result_.phases = controller_.phases();
  const auto &e = result_.core.core.observation;
  auto &r = result_.last;
  r.abi = e.abi;
  r.native = e.native.calls;
  r.samples = e.samples;
  r.sample_count = e.sample_count;
  r.controller_peak = result_.core.controller_peak;
  r.launch_attempt_ms = e.launch_attempt_ms;
  r.creation_unknown = result_.core.core.worker.creation_unknown;
  r.deadline_exceeded = e.deadline_exceeded;
  r.ipc_complete = result_.core.core.logs_complete;
  r.first_stop = e.first_failure;
  r.recovery_required = r.recovery_required || result_.core.handoff_required;
}
void Composition::finish() noexcept {
  if (result_.terminal)
    return;
  try {
    capture();
    const auto &e = result_.core.core.observation;
    auto &r = result_.last;
    if (e.deadline_exceeded)
      fail(Failure::kDeadline);
    r.security = result_.first_failure == Failure::kNone
                     ? result_.core.verdict
                     : OfflineVerdict::kUnknown;
    r.stability =
        OfflineVerdict::kNotRun; // no real OS stability claim from Fakes
    if (r.recovery_required)
      save(Stage::kRecoveryRequired);
    if (!save(Stage::kFinal))
      r.security = OfflineVerdict::kUnknown;
  } catch (...) {
    fail(Failure::kEvidence);
    result_.last.security = OfflineVerdict::kUnknown;
  }
  result_.terminal = true;
}
bool worker_main(const Frozen &f, e4::WorkerLink &l, uint32_t pid,
                 bool (*clock)(uint64_t &) noexcept) {
  return f.valid() &&
         b1::admission_only_worker_candidate(l, f.target, pid, clock);
}
int controller_process_entry(int argc, wchar_t **argv,
                             EntryPort &ports) noexcept try {
  if (argc != 1 || !argv || !argv[0])
    return 64;
  if (ports.origin() != Origin::kFake)
    return 10;
  auto c = ports.attach_controller();
  if (!c || !c->begin())
    return 10;
  while (c->pump()) {
  } // bounded inside Composition, no retry or new launch
  const auto r = c->result();
  return r.terminal && r.evidence_preserved &&
                 r.last.security == OfflineVerdict::kPass
             ? 0
             : 10;
} catch (...) {
  return 10;
}
int worker_process_entry(int argc, wchar_t **argv, EntryPort &ports) noexcept
    try {
  if (argc != 3 || !argv || !argv[0] || !argv[1] || !argv[2])
    return 64;
  std::array<uint64_t, 2> tokens{};
  for (size_t i = 0; i < 2; ++i) {
    for (size_t j = 0; argv[i + 1][j]; ++j) {
      wchar_t ch = argv[i + 1][j];
      if (j >= 20 || ch < L'0' || ch > L'9' ||
          tokens[i] > (UINT64_MAX - uint64_t(ch - L'0')) / 10)
        return 64;
      tokens[i] = tokens[i] * 10 + uint64_t(ch - L'0');
    }
    if (!tokens[i])
      return 64;
  }
  if (tokens[0] == tokens[1])
    return 64;
  if (ports.origin() != Origin::kFake)
    return 10;
  WorkerInvocation w;
  if (!ports.attach_worker(w) || !w.link || w.inherited_pipe_tokens != tokens)
    return 10;
  return worker_main(w.frozen, *w.link, w.pid, w.clock) ? 0 : 10;
} catch (...) {
  return 10;
}
} // namespace r1
} // namespace shiroha_l1_crypto
