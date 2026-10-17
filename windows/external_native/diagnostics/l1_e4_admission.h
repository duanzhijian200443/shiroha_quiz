#ifndef SHIROHA_L1_E4_ADMISSION_H_
#define SHIROHA_L1_E4_ADMISSION_H_
#include "diagnostics/l1_e4_protocol.h"

namespace shiroha_l1_crypto {
namespace e4 {
struct ClockReading {
  uint64_t utc = 0, mono = 0, session = 0;
  bool valid = false;
};
class ClockValidator {
public:
  bool accept(ClockReading r) noexcept {
    if (failed_ || !r.valid || !r.utc || !r.session)
      return failed_ = true, false;
    if (!initialized_) {
      anchor_ = last_ = r;
      initialized_ = true;
      return true;
    }
    if (r.session != anchor_.session || r.utc < last_.utc ||
        r.mono < last_.mono)
      return failed_ = true, false;
    auto wall = r.utc - anchor_.utc, elapsed = r.mono - anchor_.mono;
    if ((wall > elapsed ? wall - elapsed : elapsed - wall) > 1000)
      return failed_ = true, false;
    last_ = r;
    return true;
  }

private:
  ClockReading anchor_{}, last_{};
  bool initialized_ = false, failed_ = false;
};
inline bool window(const GrantTarget &t, ClockReading r) noexcept {
  return r.valid && r.utc >= t.window_start_ms && r.utc < t.window_end_ms &&
         t.window_end_ms - r.utc >= 30000;
}
struct ApprovalPromptModel {
  GrantTarget target;
  std::string target_hash, suffix, summary;
  const char *warning = kHumanApprovalBannerText;
};
struct ApprovalUiResponse {
  bool completed = false, cancelled = false, timed_out = false, checked = false;
  std::string suffix, displayed_hash;
};
inline bool prompt(const GrantTarget &target, const std::wstring &sid,
                   ApprovalPromptModel &out) {
  ApprovalPromptModel p;
  p.target = target;
  if (!compute_target_binding_sha256(target, sid, p.target_hash))
    return false;
  p.suffix = p.target_hash.substr(58);
  p.summary =
      std::string(kHumanApprovalBannerText) + "\nTarget=" + p.target_hash;
  const auto &t = p.target;
  const std::pair<const char *, const std::string *> fields[] = {
      {"Batch", &t.batch_id},
      {"Device", &t.device_id},
      {"OS", &t.os_id},
      {"Account digest", &t.account_identity_sha256},
      {"Source", &t.source_sha},
      {"Base", &t.base_sha},
      {"EXE", &t.exe_sha256},
      {"Dependencies", &t.dependency_manifest_sha256},
      {"Compiler", &t.compiler_id},
      {"Toolchain", &t.toolchain_manifest_sha256},
      {"STOP owner", &t.stop_owner},
      {"Recovery owner", &t.recovery_owner},
      {"Evidence owner", &t.evidence_owner},
      {"Evidence scope", &t.evidence_scope_id},
      {"Reviewer", &t.reviewer_id},
      {"Review record", &t.review_sha256},
      {"Verifier", &t.verifier_id},
      {"Verification record", &t.verification_sha256},
      {"Approval ID", &t.user_approval_id}};
  for (auto field : fields)
    p.summary += "\n" + std::string(field.first) + "=" + *field.second;
  if (t.is_admission_only()) {
    p.summary += "\nG0-L1 / L1-ADMISSION; Non-elevated primary Medium token; "
                 "Review/Verification=APPROVED";
    p.summary += "\nABI 0/0/0/0/0/0/0=0; buffers=0; direct native=0; "
                 "samples=18; deadline=30000ms";
  } else {
    p.summary += "\nG0-L1 / L1-CRYPTO; Non-elevated primary Medium token; "
                 "Review/Verification=APPROVED";
    p.summary += "\nABI 1/3/3/6/3/45/45=106; buffers=5; direct native=47; "
                 "samples=18; deadline=30000ms";
  }
  p.summary += "\nUTC=" + std::to_string(t.window_start_ms) + ".." +
               std::to_string(t.window_end_ms);
  p.summary +=
      "\nWorking/Commit/SampledHandles=" + std::to_string(t.working_set_bytes) +
      "/" + std::to_string(t.commit_bytes) + "/" + std::to_string(t.handles);
  p.summary += "\nNo automatic retry/kill/restart; recovery requires the named "
               "operator. Evidence: redacted digests/counts only.";
  out = p;
  return true;
}
inline bool confirm(const ApprovalPromptModel &p, const ApprovalUiResponse &r,
                    const GrantTarget &current, const std::wstring &sid) {
  ApprovalPromptModel expected;
  auto frozen = p.target;
  frozen.user_approved = current.user_approved;
  if (!prompt(current, sid, expected) ||
      frozen.identity() != current.identity() ||
      p.summary != expected.summary || p.suffix != expected.suffix ||
      p.target_hash != expected.target_hash)
    return false;
  std::string h;
  return r.completed && !r.cancelled && !r.timed_out && r.checked &&
         r.suffix == p.suffix && r.displayed_hash == p.target_hash &&
         compute_target_binding_sha256(current, sid, h) && h == p.target_hash;
}
// Receipt is exact 256 bytes: SAPR/version/flags; UTC/mono/session; binary
// target and account digests; full safe Batch ID length+80 bytes; zero pad;
// SHA.
using Receipt = std::array<uint8_t, 256>;
inline bool receipt(const ApprovalPromptModel &p, ClockReading r,
                    Receipt &out) {
  if (!window(p.target, r) || !r.session || !safe_id(p.target.batch_id))
    return false;
  Receipt b{};
  put(b.data(), 0x52504153, 4);
  put(b.data() + 4, 1, 2);
  put(b.data() + 6, 3, 2);
  put(b.data() + 8, r.utc, 8);
  put(b.data() + 16, r.mono, 8);
  put(b.data() + 24, r.session, 8);
  if (!decode_hex_bytes(p.target_hash, b.data() + 32, 32) ||
      !decode_hex_bytes(p.target.account_identity_sha256, b.data() + 64, 32))
    return false;
  b[96] = uint8_t(p.target.batch_id.size());
  std::copy(p.target.batch_id.begin(), p.target.batch_id.end(), b.begin() + 97);
  auto d = digest(b.data(), 224);
  std::copy(d.begin(), d.end(), b.begin() + 224);
  out = b;
  return true;
}
inline bool valid_receipt(const Receipt &b, const ApprovalPromptModel &p,
                          ClockReading issued) {
  Receipt expected{};
  return receipt(p, issued, expected) && b == expected;
}
enum class JournalStage : uint8_t { requested = 1, consumed = 2, start = 3 };
// SJNL/version/stage/zero; session,UTC,start mono; two full digests; SHA256.
using Journal = std::array<uint8_t, 128>;
inline bool journal(JournalStage stage, ClockReading r, uint64_t start,
                    const std::string &target, const std::string &objects,
                    Journal &out) {
  if (!r.valid || !r.session || !r.utc || unsigned(stage) < 1 ||
      unsigned(stage) > 3 || (stage != JournalStage::start && start))
    return false;
  Journal b{};
  put(b.data(), 0x4c4e4a53, 4);
  put(b.data() + 4, 1, 2);
  b[6] = uint8_t(stage);
  put(b.data() + 8, r.session, 8);
  put(b.data() + 16, r.utc, 8);
  put(b.data() + 24, start, 8);
  if (!decode_hex_bytes(target, b.data() + 32, 32) ||
      !decode_hex_bytes(objects, b.data() + 64, 32))
    return false;
  auto d = digest(b.data(), 96);
  std::copy(d.begin(), d.end(), b.begin() + 96);
  out = b;
  return true;
}
inline bool valid_journal(const Journal &b) {
  auto d = digest(b.data(), 96);
  return get(b.data(), 4) == 0x4c4e4a53 && get(b.data() + 4, 2) == 1 &&
         b[6] >= 1 && b[6] <= 3 && !b[7] && get(b.data() + 8, 8) &&
         get(b.data() + 16, 8) && (b[6] == 3 || !get(b.data() + 24, 8)) &&
         std::equal(d.begin(), d.end(), b.begin() + 96);
}
enum class IoResult { ok, denied, unknown };
// All methods are one attempt. Real implementations must pin parents/children,
// validate Owner/DACL, and never replace/delete an existing object. CREATE_NEW
// request is the sole cross-consumer reservation; sequential writes are NOT a
// transaction.
struct GrantIo {
  virtual ~GrantIo() = default;
  virtual bool principal(const std::wstring &sid) = 0;
  virtual IoResult issue_new(const Receipt &, BatchObjectPins &) = 0;
  virtual bool inspect(const BatchObjectPins &) = 0;
  virtual IoResult request_new(const Journal &) = 0;
  virtual IoResult burn_issued() = 0;
  virtual IoResult update_request(const Journal &) = 0;
};
class GrantFlow {
public:
  explicit GrantFlow(GrantIo &io) : io_(io) {}
  GrantFlow(const GrantFlow &) = delete;
  GrantFlow &operator=(const GrantFlow &) = delete;
  bool issue(const ApprovalPromptModel &p, const ApprovalUiResponse &r,
             const GrantTarget &current, const std::wstring &sid,
             ClockReading clock) try {
    if (attempted_)
      return false;
    attempted_ = true;
    if (!clock_.accept(clock) || !window(current, clock) ||
        !io_.principal(sid) || !confirm(p, r, current, sid))
      return false;
    Receipt b{};
    if (!receipt(p, clock, b))
      return false;
    // Only a deterministic denial is a known non-issuance. An uncertain
    // CREATE_NEW reply, and every failure after a possibly successful creation,
    // may already have left the receipt/grant on disk: keep UNKNOWN so the
    // record is never downgraded to a clean "never issued" denial.
    const auto created = io_.issue_new(b, pins_);
    if (created == IoResult::unknown)
      return uncertain();
    if (created != IoResult::ok)
      return false;
    if (!pins_.valid() || !io_.inspect(pins_))
      return uncertain();
    if (!compute_object_identity_sha256(p.target_hash, pins_,
                                        current.account_identity_sha256,
                                        object_hash_))
      return uncertain();
    target_ = current;
    target_.user_approved = true;
    hash_ = p.target_hash;
    issued_ = true;
    issued_utc_ = clock.utc;
    auto receipt_digest = digest(b.data(), b.size());
    receipt_hash_ =
        encode_hex_bytes(receipt_digest.data(), receipt_digest.size());
    record_.persisted_issuance = true;
    record_.state = GrantState::kIssued;
    return true;
  } catch (...) {
    return uncertain();
  }
  bool consume(const GrantTarget &observed, uint64_t utc) noexcept try {
    return observed.identity() == target_.identity() && utc == reading_.utc &&
           consume_reading(reading_);
  } catch (...) {
    return uncertain();
  }
  bool prepare(ClockReading r) noexcept {
    reading_ = r;
    return issued_ && record_.persisted_issuance && !record_.unknown &&
           record_.state == GrantState::kIssued && clock_.accept(r) &&
           window(target_, r);
  }
  bool start(ClockReading r) try {
    if (!record_.confirmed || record_.unknown ||
        record_.state != GrantState::kConsumed || start_attempted_)
      return false;
    start_attempted_ = true;
    if (!clock_.accept(r) || !window(target_, r) || !io_.inspect(pins_))
      return false;
    Journal j{};
    if (!journal(JournalStage::start, r, r.mono, hash_, object_hash_, j) ||
        io_.update_request(j) != IoResult::ok) {
      uncertain();
      return false;
    }
    return true;
  } catch (...) {
    return uncertain();
  }
  bool inspect(ClockReading r) try {
    return issued_ && clock_.accept(r) && io_.inspect(pins_);
  } catch (...) {
    return uncertain();
  }
  const GrantTarget &target() const noexcept { return target_; }
  const std::string &hash() const noexcept { return hash_; }
  const std::string &object_hash() const noexcept { return object_hash_; }
  const std::string &receipt_hash() const noexcept { return receipt_hash_; }
  uint64_t issued_utc() const noexcept { return issued_utc_; }
  ConsumptionRecord record() const noexcept { return record_; }

private:
  bool uncertain() noexcept {
    record_.unknown = true;
    record_.confirmed = false;
    record_.state = GrantState::kUnknown;
    return false;
  }
  bool consume_reading(ClockReading r) {
    if (!issued_ || !record_.persisted_issuance || record_.unknown ||
        record_.state != GrantState::kIssued || record_.request_started ||
        !window(target_, r) || !io_.inspect(pins_))
      return false;
    record_.request_started = true;
    Journal j{};
    if (!journal(JournalStage::requested, r, 0, hash_, object_hash_, j) ||
        io_.request_new(j) != IoResult::ok)
      return uncertain();
    if (io_.burn_issued() != IoResult::ok)
      return uncertain();
    journal(JournalStage::consumed, r, 0, hash_, object_hash_, j);
    if (io_.update_request(j) != IoResult::ok)
      return uncertain();
    record_.confirmed = true;
    record_.state = GrantState::kConsumed;
    return true;
  }
  GrantIo &io_;
  ClockValidator clock_;
  ClockReading reading_{};
  BatchObjectPins pins_{};
  GrantTarget target_;
  std::string hash_, object_hash_;
  std::string receipt_hash_;
  uint64_t issued_utc_ = 0;
  ConsumptionRecord record_{};
  bool attempted_ = false, issued_ = false, start_attempted_ = false;
};
struct WorkerStart {
  bool created = false, creation_unknown = false, token = false, image = false,
       dependencies = false, handles = false;
  bool resume_attempted = false, resume_known = false, resumed = false,
       hello = false;
  uint32_t pid = 0;
  WorkerState state() const noexcept {
    if (!created)
      return creation_unknown ? WorkerState::kUnknown
                              : WorkerState::kStartFailed;
    return token && image && dependencies && handles && resume_attempted &&
                   resume_known && resumed && hello
               ? WorkerState::kRunning
               : WorkerState::kUnknown;
  }
};
struct WorkerPort {
  virtual ~WorkerPort() = default;
  virtual ClockReading read_clock() = 0;
  // Owner keeps actual process/thread handles even when start returns UNKNOWN.
  // The returned value is observation, never transferable handle custody.
  virtual WorkerStart start_suspended(const GrantTarget &, const Digest &,
                                      ClockReading) = 0;
};
struct Evidence {
  const char *evidence_class = "OFFLINE";
  const char *backend = "FAKE";
  std::string target_hash, object_hash;
  std::string approval_id, approval_receipt_hash, stop_owner, recovery_owner,
      evidence_owner, evidence_scope;
  uint64_t approved_utc = 0;
  OfflineVerdict reviewer = OfflineVerdict::kNotRun,
                 verifier = OfflineVerdict::kNotRun;
  const char *recovery = "NOT_AUTHORIZED";
  ConsumptionRecord consumption;
  WorkerStart worker;
  bool custody_unsettled = false, logs_complete = false;
  bool owner_handles_closed = false;
  OfflineEvidence observation;
};
// Serial adapter over the SAME E2 Supervisor; no duplicate crypto ledger or
// parallel grant state enum. This is injected candidate code, never an entry
// point.
class Controller {
public:
  Controller(GrantFlow &grant, WorkerPort &worker)
      : grant_(grant), worker_(worker) {}
  Controller(const Controller &) = delete;
  Controller &operator=(const Controller &) = delete;
  bool admit(ClockReading r, const std::string &trial) {
    if (terminal() || supervisor_.state() != SupervisorState::kNotStarted)
      return false;
    if (!grant_.prepare(r)) {
      evidence_.consumption = grant_.record();
      supervisor_.refuse(StopReason::kAdmission);
      return false;
    }
    bool ok = supervisor_.admit_dual_clock(grant_, grant_.target(), r.utc,
                                           r.mono, trial);
    evidence_.consumption = grant_.record();
    evidence_.target_hash = grant_.hash();
    evidence_.object_hash = grant_.object_hash();
    evidence_.approval_id = grant_.target().user_approval_id;
    evidence_.approval_receipt_hash = grant_.receipt_hash();
    evidence_.approved_utc = grant_.issued_utc();
    evidence_.stop_owner = grant_.target().stop_owner;
    evidence_.recovery_owner = grant_.target().recovery_owner;
    evidence_.evidence_owner = grant_.target().evidence_owner;
    evidence_.evidence_scope = grant_.target().evidence_scope_id;
    if (ok) {
      Digest d{};
      decode_hex_bytes(grant_.hash(), d.data(), 32);
      channel_ = Channel(d, true, grant_.target().is_admission_only());
    }
    return ok;
  }
  bool start(ClockReading r) {
    if (terminal() || supervisor_.state() != SupervisorState::kGrantConsumed)
      return false;
    if (!grant_.start(r)) {
      evidence_.consumption = grant_.record();
      supervisor_.refuse(StopReason::kLaunch);
      return false;
    }
    ClockReading fresh{};
    try {
      fresh = worker_.read_clock();
    } catch (...) {
      supervisor_.refuse(StopReason::kLaunch);
      return false;
    }
    if (!grant_.inspect(fresh) || !window(grant_.target(), fresh)) {
      supervisor_.refuse(StopReason::kLaunch);
      return false;
    }
    if (!supervisor_.begin_launch_attempt_dual_clock(fresh.utc, fresh.mono))
      return false;
    Digest d{};
    decode_hex_bytes(grant_.hash(), d.data(), 32);
    try {
      evidence_.worker = worker_.start_suspended(grant_.target(), d, fresh);
    } catch (...) {
      evidence_.worker.creation_unknown = true;
    }
    evidence_.custody_unsettled =
        evidence_.worker.created || evidence_.worker.creation_unknown;
    return supervisor_.confirm_launch(evidence_.worker.state());
  }
  bool receive(const Frame &f, const ResourceSample &independent,
               ClockReading r) {
    if (terminal() ||
        (supervisor_.state() != SupervisorState::kRunning &&
         supervisor_.state() != SupervisorState::kStopRequested &&
         supervisor_.state() != SupervisorState::kDeadlineExceeded))
      return false;
    if (!grant_.inspect(r) || !channel_.accept(f)) {
      channel_.broken();
      stop();
      return false;
    }
    const bool open = supervisor_.poll(r.mono, true);
    if (!open)
      stop();
    auto type = get(f.data() + 6, 2);
    // The inclusive deadline (and any latched failure) closes new work. A HELLO
    // or SAMPLE accepted after that must never report success, or the caller
    // could still treat the handshake as admitted and forward ADMISSION.
    // STOP, ACK and settlement parts stay legal so bounded cleanup and owning
    // settlement remain possible.
    if ((type == 1 || type == 3) &&
        (!open || supervisor_.state() != SupervisorState::kRunning))
      return false;
    if (type == 1) {
      uint8_t expected_image[32]{};
      decode_hex_bytes(grant_.target().exe_sha256, expected_image, 32);
      if (get(f.data() + 32, 4) != evidence_.worker.pid ||
          !std::equal(expected_image, expected_image + 16, f.begin() + 48)) {
        channel_.broken();
        stop();
        return false;
      }
    }
    if (type == 3) {
      auto p = f.data() + 32;
      ResourceSample s = independent;
      // Only the controller timestamp is authoritative. Worker timestamp must
      // lie between launch and receipt in the common GetTickCount64 clock
      // domain.
      if (get(p, 8) < supervisor_.evidence().launch_attempt_ms ||
          get(p, 8) > r.mono || independent.observed_at_ms != r.mono ||
          !s.peak_working_set || !s.peak_commit || !s.handles) {
        stop();
        return false;
      }
      s.peak_working_set = (std::max)(s.peak_working_set, get(p + 8, 8));
      s.peak_commit = (std::max)(s.peak_commit, get(p + 16, 8));
      s.handles = (std::max)(s.handles, uint32_t(get(p + 24, 4)));
      s.completed_calls = uint32_t(get(p + 28, 4));
      if (!supervisor_.sample(s)) {
        stop();
        return false;
      }
    }
    if (type == 4)
      stop();
    return true;
  }
  // E5's idle IPC pump must enforce the SAME Supervisor deadline even when
  // no Worker frame arrives. This adds no work/launch/settlement authority.
  bool poll(ClockReading r, bool observer_healthy, bool *monitor_ok = nullptr) {
    if (terminal()) return false;
    // Preserve the monitoring result separately: after a Worker STOP the
    // Supervisor returns false even when cleanup is still safely bounded.
    // A failed Grant/clock observation must NOT be mistaken for that STOP.
    const bool healthy = observer_healthy && r.valid && grant_.inspect(r);
    if (monitor_ok) *monitor_ok = healthy;
    return supervisor_.poll(r.mono, healthy);
  }
  void stop() {
    if (terminal())
      return;
    supervisor_.worker_failed();
  }
  void settle(ClockReading r, bool independently_exited, bool normal_exit,
              bool owner_handles_closed) {
    if (terminal())
      return;
    bool healthy = grant_.inspect(r);
    if (!healthy || !normal_exit)
      supervisor_.worker_failed();
    if (independently_exited && healthy)
      supervisor_.observe_worker_exit(r.mono);
    L1CryptoLedger l;
    NativeObservation n;
    evidence_.logs_complete = channel_.records(l, n);
    if (!evidence_.logs_complete || !healthy || !owner_handles_closed) {
      l.settlement_unknown = true;
      n.unknown = true;
    }
    supervisor_.settle(r.mono, healthy && independently_exited, l, n);
    evidence_.owner_handles_closed =
        independently_exited && healthy && owner_handles_closed;
    if (evidence_.owner_handles_closed)
      evidence_.custody_unsettled = false;
  }
  Evidence evidence() const {
    auto e = evidence_;
    e.observation = supervisor_.evidence();
    if (supervisor_.state() == SupervisorState::kBlocked)
      e.observation.verdict = e.consumption.unknown
                                  ? OfflineVerdict::kUnknown
                                  : OfflineVerdict::kInconclusive;
    return e;
  }
  SupervisorState state() const noexcept { return supervisor_.state(); }

private:
  bool terminal() const noexcept {
    return supervisor_terminal(supervisor_.state());
  }
  GrantFlow &grant_;
  WorkerPort &worker_;
  OfflineSupervisor supervisor_;
  Evidence evidence_;
  Channel channel_{Digest{}, true};
};

struct LaunchSteps {
  virtual ~LaunchSteps() = default;
  virtual WorkerStart create() = 0;
  virtual bool token() = 0;
  virtual bool image() = 0;
  virtual bool dependencies() = 0;
  virtual bool handles() = 0;
  virtual bool resume(bool &known) = 0;
  virtual bool hello() = 0;
};
inline WorkerStart launch_once(LaunchSteps &s) {
  auto r = s.create();
  if (!r.created)
    return r;
  if (!(r.token = s.token()) || !(r.image = s.image()) ||
      !(r.dependencies = s.dependencies()) || !(r.handles = s.handles()))
    return r;
  r.resume_attempted = true;
  r.resumed = s.resume(r.resume_known);
  if (!r.resumed || !r.resume_known)
    return r;
  r.hello = s.hello();
  if (r.hello)
    r.dependencies = s.dependencies();
  return r;
}
struct WorkerLink {
  virtual ~WorkerLink() = default;
  virtual bool send(const Frame &) = 0;
  virtual bool receive(Frame &) = 0;
  virtual bool checkpoint(L1CryptoLedger &) = 0;
  // Nonblocking: EOF/error returns false; available=false is ordinary no-data.
  // All returned control frames go through the reverse-direction parser.
  virtual bool poll_control(Frame &, bool &available) = 0;
};
struct WorkerContext {
  WorkerLink *link;
  Digest target;
  uint32_t seq = 1;
  unsigned samples = 0;
  Channel *controller = nullptr;
  L1CryptoLedger *ledger = nullptr;
  bool admission_only = false;
};
inline thread_local WorkerContext *worker_context = nullptr;
inline bool worker_admission() noexcept try {
  auto c = worker_context;
  if (!c || !c->ledger || !c->controller ||
      !c->ledger->check_clock("before_work"))
    return false;
  Frame control{};
  bool available = false;
  if (!c->link->poll_control(control, available) ||
      (available &&
       (!c->controller->accept(control) || get(control.data() + 6, 2) != 4)) ||
      c->controller->stopped()) {
    c->ledger->stop("supervisor_stop", -1, "ADMISSION_BLOCKED");
    return false;
  }
  return true;
} catch (...) {
  return false;
}
inline bool worker_sample(L1CryptoLedger &l) noexcept {
  auto c = worker_context;
  if (!c || !worker_admission() || !c->link->checkpoint(l) || c->samples >= 18)
    return false;
  auto f =
      frame(Message::sample, c->seq++, uint16_t(c->samples), 18, c->target);
  auto p = f.data() + 32;
  put(p, l.last_ms, 8);
  put(p + 8, l.peak_working_set, 8);
  put(p + 16, l.peak_commit, 8);
  put(p + 24, l.handles_last, 4);
  put(p + 28, c->admission_only ? 0u : (c->samples == 17 ? 16u : c->samples), 4);
  ++c->samples;
  return c->link->send(f);
}
template <class Invoke>
bool worker_session(WorkerLink &link, const Digest &target,
                    const GrantTarget &frozen, uint32_t pid,
                    bool (*clock)(uint64_t &) noexcept, Invoke &&invoke) {
  if (worker_context || !clock || !pid || !frozen.valid())
    return false;
  WorkerContext context{&link, target};
  context.admission_only = frozen.is_admission_only();
  auto hello = frame(Message::hello, context.seq++, 0, 1, target);
  put(hello.data() + 32, pid, 4);
  put(hello.data() + 36, 3, 4);
  uint8_t image_digest[32]{};
  if (!decode_hex_bytes(frozen.exe_sha256, image_digest, 32))
    return false;
  std::copy_n(image_digest, 16, hello.begin() + 48);
  if (!link.send(hello))
    return false;
  Channel controller(target, false);
  Frame received{};
  if (!link.receive(received) || !controller.accept(received))
    return false;
  auto a = Admission::decode(received);
  if (a.working != frozen.working_set_bytes ||
      a.commit != frozen.commit_bytes || a.handles != frozen.handles)
    return false;
  L1CryptoLedger l;
  NativeObservation n;
  if (!a.bind(l))
    return false;
  l.clock_ms = clock;
  l.sample = worker_sample;
  l.native_observation = &n;
  if (!l.check_clock("before_work"))
    return false;
  worker_context = &context;
  context.controller = &controller;
  context.ledger = &l;
  n.check_admission = worker_admission;
  struct Clear {
    ~Clear() { worker_context = nullptr; }
  } clear;
  NativeObservationScope observation(n);
  try {
    invoke(l, n);
  } catch (...) {
    l.settlement_unknown = true;
    n.fail("supervisor_stop", true);
  }
  if (l.stopped || context.samples != 18) {
    auto stop = frame(Message::stop, context.seq++, 0, 1, target);
    put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
    if (!link.send(stop))
      return false;
  }
  Settlement bytes{};
  if (!encode_settlement(l, n, bytes))
    return false;
  for (auto &f : settlement_frames(bytes, target, context.seq))
    if (!link.send(f))
      return false;
  return link.receive(received) && controller.accept(received) &&
         get(received.data() + 6, 2) == 6;
}
} // namespace e4
} // namespace shiroha_l1_crypto
#endif
