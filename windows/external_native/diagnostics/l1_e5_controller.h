#ifndef SHIROHA_L1_E5_CONTROLLER_H_
#define SHIROHA_L1_E5_CONTROLLER_H_
#include "diagnostics/l1_e4_admission.h"

namespace shiroha_l1_crypto {
namespace e5 {
// Additional review scope is hashed into the EXISTING E4 evidence_scope_id.
// No Grant, journal, ledger or wire format is introduced here.
struct FixedScope {
  std::string directory, cleanup_owner, recovery_record_sha256;
  std::string controller_exe_sha256;
  uint64_t controller_working = 0, controller_commit = 0;
  uint32_t controller_handles = 0;
  bool recovery_approved = false;
  static constexpr const char *measurement =
      "GetProcessMemoryInfo.PeakWorkingSetSize.PeakPagefileUsage+GetProcessHandleCount";
  static constexpr const char *inventory =
      "approval.receipt:256;grant.bin:1;request.journal:128;anonymous-pipes:2;"
      "worker-process:1;worker-thread:1;external-evidence:0";
  bool valid() const noexcept {
    if (directory.size() < 8 || directory.size() > 240 ||
        directory.compare(0, 3, "C:\\") || directory.back() == '\\' ||
        directory.find("..") != std::string::npos)
      return false;
    for (size_t i = 3; i < directory.size(); ++i) {
      char c = directory[i];
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '\\'))
        return false;
      if (c == '\\' && directory[i - 1] == '\\') return false;
    }
    return safe_id(cleanup_owner) && hex_digest(recovery_record_sha256, 64) &&
           hex_digest(controller_exe_sha256, 64) && controller_working &&
           controller_commit && controller_handles && recovery_approved;
  }
  std::string hash() const {
    CanonicalHashBuilder b;
    b.put_str("SHIROHA_L1_E5_SCOPE_V1");
    b.put_str(directory);
    b.put_str(cleanup_owner);
    b.put_str(recovery_record_sha256);
    b.put_str(controller_exe_sha256);
    b.put_u64_le(controller_working);
    b.put_u64_le(controller_commit);
    b.put_u32_le(controller_handles);
    b.put_bool(recovery_approved);
    b.put_str(measurement);
    b.put_str(inventory);
    return b.finalize_hex();
  }
};
struct FixedTarget {
  GrantTarget grant;
  FixedScope scope;
  std::wstring sid; // internal only; never exported in Evidence
  bool valid() const {
    return scope.valid() && !grant.user_approved && grant.valid_pre_approval() &&
           grant.evidence_scope_id == scope.hash() && !sid.empty();
  }
};
inline bool presentation(const FixedTarget &t, e4::ApprovalPromptModel &base,
                         e4::ApprovalPromptModel &display) {
  if (!t.valid() || !e4::prompt(t.grant, t.sid, base)) return false;
  display = base;
  display.summary += "\nExact new C: NTFS directory=" + t.scope.directory;
  display.summary += "\nObjects=" + std::string(FixedScope::inventory);
  display.summary += "\nMeasurement=" + std::string(FixedScope::measurement);
  display.summary += "\nController EXE=" + t.scope.controller_exe_sha256;
  display.summary += "\nController Working/Commit/SampledHandles=" +
      std::to_string(t.scope.controller_working) + "/" +
      std::to_string(t.scope.controller_commit) + "/" +
      std::to_string(t.scope.controller_handles);
  display.summary += "\nCleanup owner=" + t.scope.cleanup_owner +
      "\nApproved manual custody/recovery record=" + t.scope.recovery_record_sha256;
  display.summary += "\nSuspended/stuck child: retain custody, hand off to Recovery owner, STOP."
      " No automatic kill or retry. Cooperative lab only; no malicious same-SID defense.";
  return true;
}
// Worker-side composition for a separately reviewed fixed diagnostic image.
// ADMISSION is required before resolving or invoking even the ABI function.
// A successful return means ACK received, never Native settlement or PASS.
template <class Resolver>
bool worker_candidate(e4::WorkerLink &link, const FixedTarget &frozen,
                      uint32_t pid, bool (*clock)(uint64_t &) noexcept,
                      Resolver &&resolver) {
  if (!frozen.valid() || frozen.grant.is_admission_only()) return false;
  e4::Digest d{};
  std::string hash;
  if (!compute_target_binding_sha256(frozen.grant, frozen.sid, hash) ||
      !decode_hex_bytes(hash, d.data(), d.size())) return false;
  auto t = frozen.grant;
  t.user_approved = true; // derived only; actual work still requires ADMISSION
  return e4::worker_session(link, d, t, pid, clock,
      [&](L1CryptoLedger &l, NativeObservation &) {
        L1CryptoApi api{};
        if (resolve_l1_crypto_api(l, resolver, api)) run_l1_crypto_sequence(api, l);
      });
}
struct Observation {
  ResourceSample worker{}, controller{};
  bool healthy = false, exited = false, normal_exit = false;
};
// Serial, bounded operations; no command line/configuration approval port.
// Runtime permission is independently closed in the concrete Windows port.
struct Platform : e4::WorkerPort {
  virtual bool runtime_allowed() const noexcept = 0;
  virtual bool inspect_target(const FixedTarget &) = 0;
  virtual bool approve(const e4::ApprovalPromptModel &, e4::ApprovalUiResponse &) = 0;
  virtual Observation observe() = 0;
  virtual bool next(e4::Frame &, bool &available) = 0;
  virtual bool send(const e4::Frame &) = 0;
  virtual bool close_observed_exit() = 0;
  virtual bool close_owned_io() = 0;
  // No termination/close/recovery action here: an explicit operator handoff.
  virtual void handoff(const std::string &recovery_owner, uint32_t pid) noexcept = 0;
};
struct Evidence {
  const char *evidence_class = "OFFLINE", *backend = "FAKE";
  OfflineVerdict verdict = OfflineVerdict::kNotRun;
  e4::Evidence core;
  std::string scope_hash, cleanup_owner, recovery_record_sha256;
  bool runtime_denied = false, approval_confirmed = false;
  bool admission_sent = false, ack_sent = false, stop_attempted = false;
  bool io_closed = false, handoff_required = false, finished = false;
  ResourceSample controller_peak{};
};
// Sole issuer and sole event owner. Existing E4 GrantFlow and Controller own
// ALL consume/start/IPC/Supervisor/crypto settlement state. No restart API.
class Controller {
public:
  Controller(FixedTarget target, e4::GrantIo &io, Platform &platform)
      : target_(std::move(target)), platform_(platform), flow_(io), core_(flow_, platform) {}
  Controller(const Controller &) = delete;
  Controller &operator=(const Controller &) = delete;
  bool begin() noexcept try {
    if (attempted_) return false;
    attempted_ = true;
    if (!platform_.runtime_allowed()) {
      evidence_.runtime_denied = true;
      evidence_.verdict = OfflineVerdict::kInconclusive;
      evidence_.finished = true;
      return false; // no UI, token, file, clock, pipe or close call
    }
    e4::ApprovalPromptModel base, display;
    if (!presentation(target_, base, display)) return finish(false);
    evidence_.scope_hash = target_.scope.hash();
    evidence_.cleanup_owner = target_.scope.cleanup_owner;
    evidence_.recovery_record_sha256 = target_.scope.recovery_record_sha256;
    if (!platform_.inspect_target(target_) || !controller_sample(platform_.observe()))
      return finish(false);
    e4::ApprovalUiResponse response;
    if (!platform_.approve(display, response)) return finish(false);
    // Reconstruct the exact visible text and remeasure identity AFTER the UI.
    // E4 confirm receives the canonical E4 prompt and the SAME human response;
    // no approving response is synthesized by the controller.
    e4::ApprovalPromptModel fresh_base, fresh_display;
    if (!presentation(target_, fresh_base, fresh_display) ||
        display.summary != fresh_display.summary ||
        display.target_hash != fresh_display.target_hash ||
        !e4::confirm(base, response, target_.grant, target_.sid) ||
        !platform_.inspect_target(target_) || !controller_sample(platform_.observe()))
      return finish(false);
    evidence_.approval_confirmed = true;
    auto r = reading();
    if (!flow_.issue(base, response, target_.grant, target_.sid, r) ||
        !core_.admit(reading(), target_.grant.batch_id) || !core_.start(reading()))
      return finish(false);
    // Windows start_suspended buffered the verified HELLO; it is still parsed
    // by the original E4 Controller before any ADMISSION goes to the Worker.
    return pump();
  } catch (...) { return finish(false); }

  // One nonblocking frame/event per call. Caller schedules, never retries
  // issuance/create/Resume. No-data still checks the inclusive 30s deadline.
  bool pump() noexcept try {
    if (!attempted_ || evidence_.finished) return false;
    auto r = reading();
    auto o = platform_.observe();
    // A Worker failure STOP closes new work but still owes its already-produced
    // settlement tail inside the SAME inclusive deadline, so the latched STOP
    // alone must not end the pump. poll() keeps enforcing health and the
    // launch-anchored deadline; a real deadline latch ends the bounded drain.
    if (!controller_sample(o) || !worker_sample(o)) return finish(false);
    bool monitor_ok = false;
    if (!core_.poll(r, o.healthy, &monitor_ok)) {
      const auto launch = core_.evidence().observation.launch_attempt_ms;
      // Only the already-latched Worker STOP permits bounded settlement
      // draining. A failed clock/Grant observation, terminal Supervisor state,
      // or elapsed launch deadline must end the drain and retain custody.
      if (!worker_stopped_ || !monitor_ok ||
          core_.state() != SupervisorState::kStopRequested ||
          r.mono < launch ||
          r.mono - launch >= target_.grant.max_execution_ms)
        return finish(false);
    }
    if (o.exited && parts_ == 24) return finish(o.normal_exit);
    // ACK ends the stream. EOF can precede the OS exit observation; wait only
    // on the retained process, within the SAME deadline, rather than treating
    // normal pipe closure as an abnormal exit or granting more work.
    if (evidence_.ack_sent) return true;
    e4::Frame f{};
    bool available = false;
    if (!platform_.next(f, available)) return finish(false);
    if (available) {
      o = platform_.observe();
      r = reading(); // a slow read/observation never earns fresh execution time
      o.worker.observed_at_ms = r.mono; // controller receipt timestamp, not Worker time
      if (!controller_sample(o) || !worker_sample(o) || !core_.receive(f, o.worker, r)) return finish(false);
      const auto type = e4::get(f.data() + 6, 2);
      if (type == unsigned(e4::Message::hello)) {
        if (evidence_.admission_sent || !platform_.inspect_target(target_)) return finish(false);
        // Post-HELLO re-inspection can change either process's peaks. Check
        // BOTH approved budgets before the first work permission; this fresh
        // observation never extends the original launch deadline.
        const auto fresh = platform_.observe();
        // Even a healthy, in-budget exited Worker cannot receive new work.
        // Post-inspection exit closes the first ADMISSION permanently.
        if (fresh.exited || !controller_sample(fresh) || !worker_sample(fresh))
          return finish(false);
        e4::Admission a;
        a.origin = core_.evidence().observation.launch_attempt_ms;
        a.working = target_.grant.working_set_bytes;
        a.commit = target_.grant.commit_bytes;
        a.handles = target_.grant.handles;
        // Post-inspection deadline check precedes the first work permission.
        if (!core_.poll(reading(), true)) return finish(false);
        evidence_.admission_sent = true;
        if (!platform_.send(a.encode(digest()))) return finish(false);
      } else if (type == unsigned(e4::Message::settlement) && ++parts_ == 24) {
        auto ack = e4::frame(e4::Message::ack, 2, 0, 1, digest());
        e4::put(ack.data() + 32, 1, 4);
        evidence_.ack_sent = true;
        if (!platform_.send(ack)) return finish(false);
      } else if (type == unsigned(e4::Message::stop)) {
        // The Worker failed itself and core_.receive already latched it, so no
        // HELLO/SAMPLE can be re-authorized (the E4 channel rejects both).
        // Its 24 already-produced settlement parts and the ACK they earn are
        // still collected within the SAME deadline instead of collapsing a
        // settleable failure into UNKNOWN custody.
        worker_stopped_ = true;
      }
    }
    if (o.exited && (!available || parts_ == 24)) return finish(o.normal_exit);
    return true;
  } catch (...) { return finish(false); }
  Evidence evidence() const {
    auto e = evidence_;
    if (!e.finished) e.core = core_.evidence();
    return e;
  }
private:
  e4::ClockReading reading() {
    auto r = platform_.read_clock();
    if (!clock_.accept(r)) r.valid = false;
    return r;
  }
  e4::Digest digest() const {
    e4::Digest d{};
    decode_hex_bytes(flow_.hash(), d.data(), 32);
    return d;
  }
  bool controller_sample(const Observation &o) {
    const auto &s = o.controller;
    if (!o.healthy || !s.peak_working_set || !s.peak_commit || !s.handles ||
        s.peak_working_set > target_.scope.controller_working ||
        s.peak_commit > target_.scope.controller_commit || s.handles > target_.scope.controller_handles)
      return false;
    auto &p = evidence_.controller_peak;
    p.peak_working_set = (std::max)(p.peak_working_set, s.peak_working_set);
    p.peak_commit = (std::max)(p.peak_commit, s.peak_commit);
    p.handles = (std::max)(p.handles, s.handles);
    return true;
  }
  bool worker_sample(const Observation &o) const noexcept {
    const auto &s = o.worker;
    // Live handles may legitimately drop to zero once the process is gone, so
    // they are only checked while it runs. Already-observed memory peaks are
    // NOT erased by exit and stay budget-authoritative, including on the final
    // exit observation. A healthy observation without peaks is an unavailable
    // measurement: it is an explicit downgrade, never a waived check.
    if (!o.healthy || !s.peak_working_set || !s.peak_commit) return false;
    if (!o.exited && (!s.handles || s.handles > target_.grant.handles))
      return false;
    return s.peak_working_set <= target_.grant.working_set_bytes &&
           s.peak_commit <= target_.grant.commit_bytes;
  }
  bool finish(bool normal) noexcept {
    if (evidence_.finished) return false;
    try {
      auto before = core_.evidence();
      if (before.custody_unsettled) {
        if (!normal) core_.stop();
        // At most one STOP; after ACK the reverse parser is already terminal.
        if (!normal && evidence_.admission_sent && !evidence_.ack_sent && !evidence_.stop_attempted) {
          evidence_.stop_attempted = true;
          auto stop = e4::frame(e4::Message::stop, 2, 0, 1, digest());
          e4::put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
          platform_.send(stop);
        }
        auto r = reading();
        auto o = platform_.observe();
        bool closed = o.healthy && o.exited && platform_.close_observed_exit();
        core_.settle(r, o.healthy && o.exited, normal && o.normal_exit, closed);
      }
      evidence_.io_closed = platform_.close_owned_io();
      evidence_.core = core_.evidence();
      evidence_.core.consumption = flow_.record();
      evidence_.handoff_required = evidence_.core.custody_unsettled || !evidence_.io_closed;
      if (evidence_.handoff_required)
        platform_.handoff(target_.grant.recovery_owner, evidence_.core.worker.pid);
    } catch (...) {
      evidence_.handoff_required = true;
      platform_.handoff(target_.grant.recovery_owner, 0);
    }
    evidence_.verdict = evidence_.handoff_required ? OfflineVerdict::kUnknown
        : evidence_.core.observation.verdict;
    if (evidence_.verdict == OfflineVerdict::kNotRun)
      evidence_.verdict = OfflineVerdict::kInconclusive;
    evidence_.finished = true;
    return false;
  }
  const FixedTarget target_;
  Platform &platform_;
  e4::GrantFlow flow_;
  e4::Controller core_;
  e4::ClockValidator clock_;
  Evidence evidence_;
  unsigned parts_ = 0;
  bool attempted_ = false, worker_stopped_ = false;
};
} // namespace e5
} // namespace shiroha_l1_crypto
#endif
