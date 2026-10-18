#include "diagnostics/l1_trial1a_real.h"
namespace shiroha_l1_crypto::trial1a {
namespace {
void add(s1::Counts &to, const s1::Counts &from, uint64_t n = 1) {
  for (size_t i = 0; i < s1::counter_count; ++i)
    to[i] += n * from[i];
}
PinPlan structural(PinPlan p) {
  // Validation placeholders only; never passed to an OS leaf or evidence.
  p.entry.pid = 1;
  p.entry.creation = 1;
  return p;
}
s1::Counts ui_cost(const Invocation &q) {
  s1::Counts c{};
  c[s1::os_calls] = 512 + 64 * q.plan.entry.preparation.limits.ui_events;
  return c; // <=5 HWNDs, <=128 dispatched UI events, bounded approval time
}
} // namespace
s1::Counts observation_cost() {
  s1::Counts c{};
  c[s1::os_calls] = 128;
  c[s1::handles_acquired] = c[s1::handles_closed] = 2;
  return c; // R2 runtime Token pair, device/clock/OS memory/handle queries
}
s1::Counts entry_module_cost() {
  s1::Counts c{};
  c[s1::os_calls] = 128;
  c[s1::files] = 2;
  c[s1::security_reads] = 1;
  c[s1::handles_acquired] = c[s1::handles_closed] = 1;
  return c; // actual loaded diagnostic module identity, metadata and temp close
}
s1::Counts invocation_ceiling(const Invocation &q) {
  auto c = q.plan.budget;
  add(c, observation_cost(), q.observations);
  add(c, ui_cost(q));
  add(c, process_cost()); // actual running image/Token gate BEFORE consumption
  add(c, entry_module_cost());
  const auto e = q.plan.entry.preparation.evidence_parents.size();
  add(c, s1::cost(s1::Step::evidence_open, e)); // one spent-permit file
  add(c, s1::cost(s1::Step::evidence, e), 2);
  add(c, s1::cost(s1::Step::close));
  return c;
}
bool Invocation::valid() const {
  const auto module = std::find_if(
      plan.objects.begin(), plan.objects.end(), [&](const PinInput &p) {
        return p.expected.id == entry_module_id && !p.directory &&
               p.expected.id != plan.entry.image_id;
      });
  return !plan.entry.pid && !plan.entry.creation &&
         plan.entry.invocation_binding.empty() && structural(plan).valid() &&
         safe_id(case_id) && safe_id(permit_owner) &&
         safe_id(entry_module_id) && module != plan.objects.end() &&
         resources.valid() && observations && observations <= 8192 &&
         duration_ms && duration_ms <= 30000 &&
         budget == invocation_ceiling(*this) && reviewed_binding == hash();
}
std::string Invocation::hash() const {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_TRIAL1A_REVIEWED_INVOCATION_V1");
  h.put_str(
      plan.hash()); // zero PID/time; actual identity is bound after launch
  h.put_str(case_id);
  h.put_str(permit_owner);
  h.put_str(entry_module_id);
  h.put_u64_le(resources.working);
  h.put_u64_le(resources.commit);
  h.put_u32_le(resources.handles);
  h.put_u32_le(observations);
  h.put_u64_le(duration_ms);
  for (auto n : budget)
    h.put_u64_le(n);
  return h.finalize_hex();
}
e4::ApprovalPromptModel invocation_prompt(const Invocation &q) {
  e4::ApprovalPromptModel p;
  p.target = q.plan.entry.preparation.frozen.target.grant;
  p.target_hash = q.hash();
  p.suffix = p.target_hash.substr(58);
  p.summary =
      std::string(kHumanApprovalBannerText) +
      "\nTRIAL 1A ONLY: consume once; no Grant, Worker, retry or deletion" +
      "\nPacket=" + p.target_hash + "\nBatch=" + p.target.batch_id +
      "\nCase=" + q.case_id +
      "\nAccount digest=" + p.target.account_identity_sha256 +
      "\nSource=" + p.target.source_sha + "\nBase=" + p.target.base_sha +
      "\nEXE=" + q.plan.entry.preparation.frozen.manifest.build.controller +
      "\nInventory=" + q.plan.hash() + "\nPermit owner=" + q.permit_owner +
      "\nEntry module=" + q.entry_module_id +
      "\nReviewer=" + p.target.reviewer_id +
      "\nReview=" + p.target.review_sha256 +
      "\nVerifier=" + p.target.verifier_id +
      "\nVerification=" + p.target.verification_sha256 +
      "\nUTC=" + std::to_string(p.target.window_start_ms) + ".." +
      std::to_string(p.target.window_end_ms) +
      "\nDuration=" + std::to_string(q.duration_ms) +
      "\nWS/Commit/Handles=" + std::to_string(q.resources.working) + "/" +
      std::to_string(q.resources.commit) + "/" +
      std::to_string(q.resources.handles) +
      "\nObservations=" + std::to_string(q.observations) +
      "\nReview the exact private packet before entering the six-character "
      "suffix.";
  const auto &f = q.plan.entry.preparation.frozen;
  p.summary += "\nDevice=" + f.manifest.device_sha256 +
               "\nOS=" + f.manifest.os_sha256 +
               "\nRoot (private)=" + f.target.scope.directory +
               "\nEvidence directory (private)=" +
               q.plan.entry.preparation.evidence_directory +
               "\nPin owner=" + f.manifest.pin_owner +
               "\nEvidence owner=" + f.manifest.evidence_owner +
               "\nProcess owner=" + q.plan.entry.process_owner +
               "\nSTOP owner=" + p.target.stop_owner +
               "\nRecovery owner=" + p.target.recovery_owner +
               "\nDependencies=" + p.target.dependency_manifest_sha256 +
               "\nToolchain=" + p.target.toolchain_manifest_sha256;
  const char *names[] = {"directories",      "files",
                         "security_reads",   "os_calls",
                         "root_creates",     "security_sets",
                         "evidence_creates", "handles_acquired",
                         "handles_closed",   "hash_reads",
                         "hash_bytes",       "evidence_writes",
                         "evidence_flushes", "evidence_bytes"};
  for (size_t i = 0; i < s1::counter_count; ++i)
    p.summary +=
        "\nBudget " + std::string(names[i]) + "=" + std::to_string(q.budget[i]);
  return p;
}
RealEntry::RealEntry(Invocation q, InvocationPort &c, PinPort &p,
                     s1::Operations &o, ProcessPort &m, r1::EvidenceSink &s)
    : request_(std::move(q)), control_(c), pins_(p), operations_(o),
      process_(m), sink_(s) {}
bool RealEntry::stop() {
  stopped_ = true;
  result_.reserved = overhead_;
  if (acquisition_)
    add(result_.reserved, acquisition_->reserved());
  result_.unknown = result_.approved;
  result_.settled = false;
  return false;
}
bool RealEntry::reserve(const s1::Counts &c) {
  auto used = overhead_;
  if (acquisition_)
    add(used, acquisition_->reserved());
  for (size_t i = 0; i < s1::counter_count; ++i)
    if (used[i] > request_.budget[i] || c[i] > request_.budget[i] - used[i])
      return stop();
  add(overhead_, c);
  result_.reserved = overhead_;
  if (acquisition_)
    add(result_.reserved, acquisition_->reserved());
  return true;
}
bool RealEntry::checkpoint() {
  if (stopped_ || result_.observations == request_.observations ||
      !reserve(observation_cost()))
    return stop();
  ++result_.observations; // reserve attempts before any external call
  const auto m = control_.observe();
  const auto &f = request_.plan.entry.preparation.frozen;
  const auto &r = m.runtime.facts;
  if (r.origin != expected_ || !r.pid || !r.creation_time ||
      r.sid != f.target.sid ||
      r.account != f.target.grant.account_identity_sha256 ||
      r.os != f.manifest.os_sha256 ||
      m.runtime.device_sha256 != f.manifest.device_sha256 ||
      !r.primary_medium || !r.non_elevated || !clock_.accept(m.clock) ||
      m.clock.session != r.creation_time ||
      m.clock.utc < f.target.grant.window_start_ms ||
      m.clock.utc >= f.target.grant.window_end_ms ||
      !m.resources.peak_working_set || !m.resources.peak_commit ||
      !m.resources.handles || m.resources.observed_at_ms != m.clock.mono)
    return stop();
  if (!initialized_) {
    if (f.target.grant.window_end_ms - m.clock.utc < request_.duration_ms)
      return stop();
    initialized_ = true;
    result_.pid = r.pid;
    result_.creation = r.creation_time;
    start_ = m.clock.mono;
  }
  if (r.pid != result_.pid || r.creation_time != result_.creation ||
      m.clock.mono - start_ >= request_.duration_ms ||
      m.resources.peak_working_set > request_.resources.working ||
      m.resources.peak_commit > request_.resources.commit ||
      m.resources.handles > request_.resources.handles)
    return stop();
  result_.peak.peak_working_set =
      (std::max)(result_.peak.peak_working_set, m.resources.peak_working_set);
  result_.peak.peak_commit =
      (std::max)(result_.peak.peak_commit, m.resources.peak_commit);
  result_.peak.handles = (std::max)(result_.peak.handles, m.resources.handles);
  result_.peak.observed_at_ms = m.clock.mono;
  result_.utc_ms = m.clock.utc;
  result_.mono_ms = m.clock.mono;
  return true;
}
bool RealEntry::receipt(const r1::SinkReceipt &a, const r1::Record &r) const {
  return a.origin == expected_ && a.status == r1::IoStatus::kOk &&
         a.sequence == r.sequence && a.record_sha256 == r.hash();
}
r1::Record RealEntry::record(r1::Stage stage) {
  const auto &f = request_.plan.entry.preparation.frozen;
  const auto &g = f.target.grant;
  r1::Record r;
  r.stage = stage;
  r.sequence = result_.last.sequence + 1;
  r.previous = result_.last.sequence ? result_.last.hash() : "";
  r.batch = g.batch_id;
  r.target = f.hash();
  r.reviewer = g.reviewer_id;
  r.verifier = g.verifier_id;
  r.review_sha256 = g.review_sha256;
  r.verification_sha256 = g.verification_sha256;
  r.pid = result_.pid;
  r.creation_time = result_.creation;
  r.utc_ms = result_.utc_ms;
  r.mono_ms = result_.mono_ms;
  r.approved = r.consumed = true;
  r.controller_peak = result_.peak;
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_TRIAL1A_INVOCATION_LEDGER_V1");
  h.put_str(request_.hash());
  h.put_str(runtime_.hash());
  h.put_u64_le(
      start_); // post-approval observation origin, NOT invented launch time
  h.put_u32_le(result_.preconsume_process_checks);
  h.put_u32_le(result_.entry_module_checks);
  for (auto n : result_.reserved)
    h.put_u64_le(n);
  for (auto n : {result_.entry_starts, result_.approvals, result_.observations,
                 result_.consume_attempts, result_.finish_attempts,
                 result_.permit_closes})
    h.put_u32_le(n);
  if (acquisition_)
    h.put_str(acquisition_->result().last.hash());
  h.put_bool(result_.prepared);
  h.put_bool(acquisition_ && acquisition_->settled());
  r.manifest = h.finalize_hex();
  // Final permit close is still outstanding: never persist aggregate PASS.
  return r;
}
bool RealEntry::run_offline() { return run(r1::Origin::kFake); }
bool RealEntry::run(r1::Origin origin) try {
  if (result_.attempted)
    return false;
  result_.attempted = true;
  expected_ = origin;
  if ((origin != r1::Origin::kFake && origin != r1::Origin::kWindowsApi) ||
      control_.origin() != origin || pins_.origin() != origin ||
      operations_.origin() != origin || process_.origin() != origin ||
      !request_.valid())
    return stop();
  if (origin == r1::Origin::kWindowsApi &&
      request_.plan.entry.preparation.frozen.manifest.build.origin !=
          r1::Origin::kIndependentBuild)
    return stop();
  // The externally launched current image is counted once. No child launch.
  result_.entry_starts = 1;
  if (!reserve(ui_cost(request_)))
    return false;
  ++result_.approvals;
  const auto p = invocation_prompt(request_);
  e4::ApprovalUiResponse a;
  if (!control_.approve(p, a) || !a.completed || a.cancelled || a.timed_out ||
      !a.checked || a.suffix != p.suffix || a.displayed_hash != p.target_hash)
    return stop();
  result_.approved = true;
  if (!checkpoint())
    return false;
  runtime_ = request_.plan;
  runtime_.entry.pid = result_.pid;
  runtime_.entry.creation = result_.creation;
  runtime_.entry.invocation_binding = request_.hash();
  if (!runtime_.valid() || !control_.attach(runtime_))
    return stop();
  acquisition_ =
      std::make_unique<Acquisition>(runtime_, static_cast<PinPort &>(*this),
                                    static_cast<s1::Operations &>(*this),
                                    static_cast<r1::EvidenceSink &>(*this),
                                    static_cast<ProcessPort &>(*this));
  if (!acquisition_->run_controlled(origin) || stopped_)
    return stop();
  result_.prepared = true;
  if (!acquisition_->settle_once(
          runtime_.entry.preparation.frozen.manifest.pin_owner,
          runtime_.entry.preparation.frozen.manifest.evidence_owner) ||
      !checkpoint())
    return stop();
  result_.settled = true;
  return true;
} catch (...) {
  return stop();
}

AcquiredPin RealEntry::acquire(size_t i, const PinInput &p, uintptr_t h) {
  if (!checkpoint())
    return {};
  auto r = pins_.acquire(i, p, h);
  if (!checkpoint())
    return {}; // underlying Owner retains ambiguous handles
  return r;
}
s1::Handoff RealEntry::bind(const PinPlan &p,
                            const std::vector<AcquiredPin> &v) {
  if (!checkpoint())
    return {};
  auto a = pins_.bind(p, v);
  if (a.status != r1::IoStatus::kOk || a.request != p.hash() ||
      a.owner != p.entry.preparation.frozen.manifest.pin_owner ||
      a.pin != borrow_hash(p, v) || !checkpoint())
    return {};
  const auto e = p.entry.preparation.evidence_parents.size();
  if (!reserve(entry_module_cost()))
    return {};
  ++result_.entry_module_checks;
  if (!control_.entry_module(request_.entry_module_id) || !checkpoint()) {
    stop();
    return {};
  }
  if (!reserve(process_cost()))
    return {};
  ++result_.preconsume_process_checks;
  const auto process = process_.measure();
  const auto image = std::find_if(
      p.entry.preparation.frozen.manifest.pins.begin(),
      p.entry.preparation.frozen.manifest.pins.end(),
      [&](const r1::Pin &pin) { return pin.id == p.entry.image_id; });
  if (image == p.entry.preparation.frozen.manifest.pins.end() ||
      process.origin != expected_ || !process.checked ||
      process.pid != result_.pid || process.creation != result_.creation ||
      !(process.image == image->object) ||
      process.security_sha256 != image->security_sha256 || !checkpoint()) {
    stop();
    return {};
  }
  if (!reserve(s1::cost(s1::Step::evidence_open, e)) ||
      !reserve(s1::cost(s1::Step::evidence, e)))
    return {};
  ++result_.consume_attempts;
  auto r = record(r1::Stage::kConsumed);
  if (!receipt(control_.consume(r), r) || !checkpoint()) {
    stop();
    return {};
  }
  result_.consumed = true;
  result_.last = r;
  return a; // Entry/S1 can begin ONLY after durable exclusive consumption ACK
}
s1::Handoff RealEntry::release_borrow(const std::string &r,
                                      const std::string &h) {
  if (!checkpoint())
    return {};
  // The permit stream borrows the SAME evidence ancestors. Flush/close it
  // before acknowledging upstream release; never use a closed parent HANDLE.
  if (!reserve(s1::cost(s1::Step::evidence,
                        runtime_.entry.preparation.evidence_parents.size())))
    return {};
  ++result_.finish_attempts;
  auto final = record(r1::Stage::kFinal);
  if (!receipt(control_.finish(final), final) || !checkpoint()) {
    stop();
    return {};
  }
  result_.last = final;
  if (!reserve(s1::cost(s1::Step::close)))
    return {};
  ++result_.permit_closes;
  if (!control_.close_permit(request_.permit_owner) || !checkpoint()) {
    stop();
    return {};
  }
  auto a = pins_.release_borrow(r, h);
  return checkpoint() ? a : s1::Handoff{};
}
bool RealEntry::close(size_t i, const std::string &o, uintptr_t h) {
  return checkpoint() && pins_.close(i, o, h) && checkpoint();
}
ProcessObservation RealEntry::measure() {
  if (!result_.consumed || !checkpoint())
    return {};
  auto r = process_.measure();
  return checkpoint() ? r : ProcessObservation{};
}
s1::Runtime RealEntry::identity() {
  if (!result_.consumed || !checkpoint())
    return {};
  auto r = operations_.identity();
  return checkpoint() ? r : s1::Runtime{};
}
s1::Observation RealEntry::parent(size_t i) {
  if (!checkpoint())
    return {};
  auto r = operations_.parent(i);
  return checkpoint() ? r : s1::Observation{};
}
bool RealEntry::artifact(size_t i, r1::Pin &p, uint32_t &n) {
  return checkpoint() && operations_.artifact(i, p, n) && checkpoint();
}
s1::Creation RealEntry::create_root() {
  if (!result_.consumed || !checkpoint())
    return s1::Creation::unknown;
  auto r = operations_.create_root();
  return checkpoint() ? r : s1::Creation::unknown;
}
s1::Observation RealEntry::root() {
  if (!checkpoint())
    return {};
  auto r = operations_.root();
  return checkpoint() ? r : s1::Observation{};
}
bool RealEntry::open_evidence() {
  return checkpoint() && operations_.open_evidence() && checkpoint();
}
s1::Handoff RealEntry::handoff(const r1::Pin &p, const std::string &h) {
  if (!checkpoint())
    return {};
  auto r = operations_.handoff(p, h);
  return checkpoint() ? r : s1::Handoff{};
}
bool RealEntry::close_root() {
  return checkpoint() && operations_.close_root() && checkpoint();
}
bool RealEntry::close_evidence() {
  return checkpoint() && operations_.close_evidence() && checkpoint();
}
r1::SinkReceipt RealEntry::preserve(const r1::Record &r) {
  if (!checkpoint())
    return {};
  auto a = sink_.preserve(r);
  return checkpoint() ? a : r1::SinkReceipt{};
}
} // namespace shiroha_l1_crypto::trial1a
