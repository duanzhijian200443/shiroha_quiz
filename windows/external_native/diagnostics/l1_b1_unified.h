#ifndef SHIROHA_L1_B1_UNIFIED_H_
#define SHIROHA_L1_B1_UNIFIED_H_

#include "diagnostics/l1_e5_controller.h"
#include "native_core.h"
#include "protected_objects.h"

namespace shiroha_l1_crypto {
namespace b1 {

// G0-L0 SOURCE / COMPILE / FAKE ONLY.
// Unified L1 diagnostic infrastructure for B1-A..B1-E.
// Real Windows execution remains unconditionally denied across all trials.
inline constexpr bool kUnifiedRealExecutionAuthorized = false;

enum class TrialKind : uint8_t {
  kAdmission = 1,
  kCrypto = 2,
  kObjects = 3,
  kStore = 4,
  kRelease = 5
};

enum class OperationDomain : uint8_t {
  kAdmissionHandshake = 1,
  kCryptoAbiPrimitive = 2,
  kObjectsLockAndPublish = 3,
  kStoreDpapiAndTransaction = 4,
  kReleaseOwnedResource = 5
};

inline const char *trial_scope_name(TrialKind kind) noexcept {
  switch (kind) {
    case TrialKind::kAdmission:
      return "L1-ADMISSION";
    case TrialKind::kCrypto:
      return "L1-CRYPTO";
    case TrialKind::kObjects:
      return "L1-OBJECTS";
    case TrialKind::kStore:
      return "L1-STORE";
    case TrialKind::kRelease:
      return "L1-RELEASE";
  }
  return "UNKNOWN";
}

inline uint64_t candidate_deadline_ms(TrialKind kind) noexcept {
  switch (kind) {
    case TrialKind::kAdmission:
    case TrialKind::kCrypto:
    case TrialKind::kRelease:
      return 30000;
    case TrialKind::kObjects:
    case TrialKind::kStore:
      return 60000;
  }
  return 0;
}

// Strict cross-Trial Operation Allowlist isolation:
// - L1-ADMISSION allows only admission handshake and release of its own handles;
//   zero crypto, zero objects, zero store operations.
// - L1-CRYPTO allows admission handshake, the 7 ABI-3 crypto symbols, and its
//   own release; it NEVER authorizes L1-OBJECTS or L1-STORE operations.
// - L1-OBJECTS allows only object lock/inspect/publish/replace/readback and its
//   own release; zero crypto and zero store/DPAPI operations.
// - L1-STORE allows only DPAPI protect/unprotect and single-kind store
//   begin/commit/abort plus its own release; zero crypto keygen/sign/verify.
// - L1-RELEASE allows only release/observation of already-granted owned objects.
inline bool operation_allowed_for_trial(TrialKind trial,
                                        OperationDomain domain) noexcept {
  switch (trial) {
    case TrialKind::kAdmission:
      return domain == OperationDomain::kAdmissionHandshake ||
             domain == OperationDomain::kReleaseOwnedResource;
    case TrialKind::kCrypto:
      return domain == OperationDomain::kAdmissionHandshake ||
             domain == OperationDomain::kCryptoAbiPrimitive ||
             domain == OperationDomain::kReleaseOwnedResource;
    case TrialKind::kObjects:
      return domain == OperationDomain::kObjectsLockAndPublish ||
             domain == OperationDomain::kReleaseOwnedResource;
    case TrialKind::kStore:
      return domain == OperationDomain::kStoreDpapiAndTransaction ||
             domain == OperationDomain::kReleaseOwnedResource;
    case TrialKind::kRelease:
      return domain == OperationDomain::kReleaseOwnedResource;
  }
  return false;
}

// ============================================================================
// B1-A & B1-B: L1-ADMISSION Candidate & Shared Contract with L1-CRYPTO
// ============================================================================

struct PhaseObservation {
  bool started = false;
  bool completed = false;
  bool succeeded = false;
  bool unknown = false;
};

enum class ProcessLifecycleStage : uint8_t {
  kUncreated = 0,
  kCreatedSuspended = 1,
  kResumed = 2,
  kExited = 3,
  kHandlesReleased = 4,
  kCustodyRetainedUnknown = 5
};

struct AdmissionPhaseLedger {
  PhaseObservation consume{};
  PhaseObservation create{};
  PhaseObservation resume{};
  PhaseObservation ipc{};
  PhaseObservation close{};
  ProcessLifecycleStage lifecycle = ProcessLifecycleStage::kUncreated;
  bool uncreated_observed = true;
  bool created_suspended_observed = false;
  bool resumed_observed = false;
  bool exited_observed = false;
  bool handles_released_observed = false;
  bool custody_retained = false;
};

// Admission-only Worker sequence: zero crypto symbols resolved, zero ABI calls,
// zero direct native calls, 18 resource samples with completed_calls=0.
inline void run_l1_admission_only_sequence(L1CryptoLedger &l,
                                           NativeObservation &n) noexcept {
  if (l.abi_attempted_total != 0 || l.attempted != 0 || n.acquired != 0) {
    l.stop("before_work", SHIROHA_NATIVE_UNAVAILABLE, "UNAUTHORIZED_ACCESS");
    return;
  }
  // Sample 1 is the pre-work baseline, samples 2..17 follow each admission/IPC
  // step, sample 18 is the final settlement observation.
  for (unsigned i = 0; i < 18; ++i) {
    const char *stage = i == 0    ? "before_work"
                        : i == 17 ? "after_final_settlement"
                                  : "after_admission_step";
    if (!l.observe(stage)) {
      return;
    }
  }
}

inline bool admission_only_worker_candidate(
    e4::WorkerLink &link, const e5::FixedTarget &frozen, uint32_t pid,
    bool (*clock)(uint64_t &) noexcept) {
  if (!frozen.valid() || !frozen.grant.is_admission_only()) return false;
  e4::Digest d{};
  std::string hash;
  if (!compute_target_binding_sha256(frozen.grant, frozen.sid, hash) ||
      !decode_hex_bytes(hash, d.data(), d.size()))
    return false;
  auto t = frozen.grant;
  t.user_approved = true;
  return e4::worker_session(link, d, t, pid, clock,
                            [](L1CryptoLedger &l, NativeObservation &n) {
                              run_l1_admission_only_sequence(l, n);
                            });
}

// Compile-only isolated Admission-only Worker entry (defined in
// l1_b1_admission_worker.cpp; zero crypto symbols linked).
bool admission_only_worker(const e5::FixedTarget &frozen,
                           HANDLE controller_read,
                           HANDLE controller_write) noexcept;

// Unified Controller wrapper for B1-A (L1-ADMISSION) and B1-B (L1-CRYPTO)
// that reuses e5::Controller without duplicating GrantFlow, Channel, or
// OfflineSupervisor, while recording explicit phase start/result/UNKNOWN and
// the 5 process lifecycle states.
class UnifiedAdmissionController {
 public:
  UnifiedAdmissionController(e5::FixedTarget target, e4::GrantIo &io,
                             e5::Platform &platform)
      : target_(std::move(target)),
        controller_(target_, io, platform),
        admission_only_(target_.grant.is_admission_only()) {}
  UnifiedAdmissionController(const UnifiedAdmissionController &) = delete;
  UnifiedAdmissionController &operator=(const UnifiedAdmissionController &) =
      delete;

  bool begin() noexcept {
    if (attempted_) return false;
    attempted_ = true;
    bool ok = controller_.begin();
    sync_phases();
    return ok;
  }

  bool pump() noexcept {
    if (!attempted_) return false;
    bool ok = controller_.pump();
    sync_phases();
    return ok;
  }

  bool allow_operation(OperationDomain domain) const noexcept {
    const TrialKind kind =
        admission_only_ ? TrialKind::kAdmission : TrialKind::kCrypto;
    return operation_allowed_for_trial(kind, domain);
  }

  e5::Evidence evidence() const { return controller_.evidence(); }
  const AdmissionPhaseLedger &phases() const noexcept { return phases_; }

 private:
  void sync_phases() noexcept {
    const auto ev = controller_.evidence();
    const auto &c = ev.core.consumption;
    const auto &w = ev.core.worker;
    const auto &obs = ev.core.observation;

    // 1. Consume phase
    if (c.persisted_issuance || c.request_started || c.unknown ||
        c.state != GrantState::kUnissued) {
      phases_.consume.started = true;
      phases_.consume.unknown = c.unknown || c.state == GrantState::kUnknown;
      phases_.consume.succeeded =
          c.confirmed && !phases_.consume.unknown &&
          c.state == GrantState::kConsumed;
      phases_.consume.completed =
          phases_.consume.succeeded || phases_.consume.unknown || ev.finished;
    }

    // 2. Create phase
    if (w.created || w.creation_unknown ||
        obs.worker_state != WorkerState::kNotStarted) {
      phases_.create.started = true;
      phases_.create.unknown = w.creation_unknown;
      phases_.create.succeeded = w.created && !w.creation_unknown;
      phases_.create.completed = true;
    }

    // 3. Resume phase (after suspended creation + token/image/dep/handle checks)
    if (w.created) {
      phases_.created_suspended_observed = true;
      if (w.resume_attempted || !w.token || !w.image || !w.dependencies ||
          !w.handles) {
        phases_.resume.started = true;
        phases_.resume.unknown = w.resume_attempted && !w.resume_known;
        phases_.resume.succeeded = w.token && w.image && w.dependencies &&
                                   w.handles && w.resume_attempted &&
                                   w.resume_known && w.resumed;
        phases_.resume.completed = true;
      }
      if (phases_.resume.succeeded) {
        phases_.resumed_observed = true;
      }
    }

    // 4. IPC phase
    if (w.hello || ev.admission_sent || obs.sample_count > 0 ||
        ev.core.logs_complete) {
      phases_.ipc.started = true;
      phases_.ipc.unknown =
          ev.finished && (!ev.core.logs_complete || obs.settlement_incomplete);
      phases_.ipc.succeeded =
          w.hello && ev.admission_sent && ev.ack_sent && ev.core.logs_complete;
      phases_.ipc.completed = ev.ack_sent || ev.finished;
    }

    // 5. Close phase
    if (obs.process_exit_observed) {
      phases_.exited_observed = true;
    }
    if (ev.finished && (w.created || w.creation_unknown)) {
      phases_.close.started = true;
      phases_.close.completed = true;
      phases_.close.succeeded =
          obs.process_exit_observed && ev.core.owner_handles_closed &&
          ev.io_closed && !ev.handoff_required;
      phases_.close.unknown = !phases_.close.succeeded;
      if (phases_.close.succeeded) {
        phases_.handles_released_observed = true;
      }
    }

    phases_.custody_retained =
        (ev.finished && ev.core.custody_unsettled) || ev.handoff_required ||
        phases_.create.unknown || phases_.resume.unknown ||
        phases_.close.unknown || (w.created && !phases_.resume.succeeded);

    if (phases_.custody_retained &&
        (w.created || w.creation_unknown || ev.finished)) {
      phases_.lifecycle = ProcessLifecycleStage::kCustodyRetainedUnknown;
    } else if (phases_.handles_released_observed) {
      phases_.lifecycle = ProcessLifecycleStage::kHandlesReleased;
    } else if (phases_.exited_observed) {
      phases_.lifecycle = ProcessLifecycleStage::kExited;
    } else if (phases_.resumed_observed) {
      phases_.lifecycle = ProcessLifecycleStage::kResumed;
    } else if (phases_.created_suspended_observed) {
      phases_.lifecycle = ProcessLifecycleStage::kCreatedSuspended;
    } else {
      phases_.lifecycle = ProcessLifecycleStage::kUncreated;
    }
  }

  e5::FixedTarget target_;
  e5::Controller controller_;
  AdmissionPhaseLedger phases_{};
  bool attempted_ = false;
  bool admission_only_ = false;
};

// ============================================================================
// B1-E: L1-RELEASE Unified Resource Settlement Model
// ============================================================================

enum class ResourceKind : uint8_t {
  kProcessHandle = 1,
  kThreadHandle = 2,
  kPipeHandle = 3,
  kAbiBuffer = 4,
  kCngProvider = 5,
  kCngKey = 6,
  kCertContext = 7,
  kLocalAllocBlob = 8,
  kProtectedLockLease = 9,
  kStoreTicket = 10,
  kTempFileHandle = 11,
  kPublishedObject = 12
};

struct OwnedResourceEntry {
  uint64_t resource_id = 0;
  std::string owner_id;
  ResourceKind kind = ResourceKind::kAbiBuffer;
  uint64_t parent_resource_id = 0;  // e.g. underlying native resource for buffer
  bool release_attempted = false;
  bool released = false;
  bool quarantined = false;
  bool process_exit_verified = false;
};

class B1ReleaseLedger {
 public:
  static constexpr uint64_t kMaxReleaseMs = 30000;

  explicit B1ReleaseLedger(TrialKind trial = TrialKind::kRelease) noexcept
      : trial_(trial) {}

  bool begin_window(uint64_t start_ms) noexcept {
    // Do not restore admission after a failed pre-window operation.
    if (clock_started_ || settled_ || stopped_ || observation_lost_ ||
        first_failure_code_ != std::string("NONE"))
      return false;
    clock_started_ = true;
    start_ms_ = last_ms_ = start_ms;
    return true;
  }

  bool advance_clock(uint64_t now_ms) noexcept {
    if (!clock_started_ || now_ms < last_ms_) {
      // An invalid clock ends new work, but never cancels a legal owned release.
      mark_observation_lost();
      return false;
    }
    if (settled_ || stopped_ || deadline_exceeded_) return false;
    last_ms_ = now_ms;
    if (now_ms - start_ms_ >= kMaxReleaseMs) {
      deadline_exceeded_ = true;
      stopped_ = true;
      // Inclusive 30s deadline stops new work, but NEVER forcibly terminates
      // an in-flight synchronous OS/Native call.
      if (in_flight_sync_calls_ > 0) {
        unknown_ = true;
      }
      latch_failure("deadline_exceeded", "BUDGET_EXCEEDED",
                    in_flight_sync_calls_ > 0);
      return false;
    }
    return true;
  }

  // Register a newly acquired resource with a unique resource_id and valid
  // owner_id. Rejects acquisition after STOP or deadline.
  bool register_acquired(uint64_t resource_id, const std::string &owner_id,
                         ResourceKind kind,
                         uint64_t parent_resource_id = 0) noexcept {
    // A resource cannot be admitted without a live, observed timing window.
    if (!clock_started_ || observation_lost_) {
      mark_observation_lost();
      return false;
    }
    if (settled_ || stopped_ || deadline_exceeded_ || !resource_id ||
        !safe_id(owner_id)) {
      latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN", true);
      return false;
    }
    for (const auto &entry : entries_) {
      if (entry.resource_id == resource_id) {
        latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN",
                      true);
        return false;
      }
    }
    entries_.push_back({resource_id, owner_id, kind, parent_resource_id, false,
                        false, false, false});
    ++acquired_count_;
    ++still_owned_count_;
    return true;
  }

  // STOP blocks new acquisitions/work, but NEVER blocks other independent
  // Owners from performing their single legal release attempt.
  void request_stop(const char *stage = "supervisor_stop",
                    const char *code = "ADMISSION_BLOCKED") noexcept {
    stopped_ = true;
    if (first_failure_code_ == std::string("NONE")) {
      first_failure_stage_ = stage ? stage : "supervisor_stop";
      first_failure_code_ = code ? code : "ADMISSION_BLOCKED";
    }
  }

  void begin_sync_call() noexcept { ++in_flight_sync_calls_; }
  void end_sync_call() noexcept {
    if (in_flight_sync_calls_ > 0) --in_flight_sync_calls_;
  }

  void observe_process_exit(uint64_t process_resource_id) noexcept {
    for (auto &entry : entries_) {
      if (entry.resource_id == process_resource_id &&
          entry.kind == ResourceKind::kProcessHandle) {
        entry.process_exit_verified = true;
      }
    }
  }

  void mark_observation_lost() noexcept {
    observation_lost_ = true;
    stopped_ = true;
    unknown_ = true;
    latch_failure("resource_observation_failed", "MEASUREMENT_UNAVAILABLE",
                  true);
  }

  // Single legal release attempt by the exact Owner.
  // - Duplicate release attempt -> fails and latches OWNERSHIP_UNKNOWN.
  // - Wrong owner -> fails and latches OWNERSHIP_UNKNOWN.
  // - CloseHandle on a process handle without observed exit -> quarantines as
  //   SETTLEMENT_UNKNOWN (CloseHandle never proves process termination).
  // - Void buffer release settles only the buffer, NEVER its parent/underlying
  //   native resource.
  // - Failed release -> never retried; quarantines resource and latches UNKNOWN.
  bool release_once(uint64_t resource_id, const std::string &caller_owner,
                    bool os_release_succeeded) noexcept {
    if (settled_) return false;
    for (auto &entry : entries_) {
      if (entry.resource_id != resource_id) continue;
      if (entry.owner_id != caller_owner) {
        ++unowned_release_attempts_;
        latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN",
                      true);
        return false;
      }
      if (entry.release_attempted) {
        ++duplicate_release_attempts_;
        latch_failure("duplicate_buffer_release", "OWNERSHIP_UNKNOWN", true);
        return false;
      }
      entry.release_attempted = true;
      ++release_attempts_;
      if (entry.kind == ResourceKind::kProcessHandle &&
          !entry.process_exit_verified) {
        entry.quarantined = true;
        ++quarantined_count_;
        unknown_ = true;
        latch_failure("buffer_release_unknown", "SETTLEMENT_UNKNOWN", true);
        return false;
      }
      if (!os_release_succeeded) {
        entry.quarantined = true;
        ++quarantined_count_;
        unknown_ = true;
        latch_failure("buffer_release_unknown", "SETTLEMENT_UNKNOWN", true);
        return false;
      }
      entry.released = true;
      ++released_count_;
      if (still_owned_count_ > 0) --still_owned_count_;
      return true;
    }
    ++unowned_release_attempts_;
    latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN", true);
    return false;
  }

  // Deleting an object without verified ownership proof and explicit delete
  // authorization is strictly forbidden.
  bool attempt_delete_object(uint64_t resource_id,
                             const std::string &caller_owner,
                             bool verified_ownership_proof,
                             bool delete_explicitly_authorized) noexcept {
    if (!verified_ownership_proof) {
      ++forbidden_delete_attempts_;
      latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN", true);
      return false;
    }
    if (!delete_explicitly_authorized) {
      ++forbidden_delete_attempts_;
      latch_failure("supervisor_stop", "UNAUTHORIZED_ACCESS", false);
      return false;
    }
    for (const auto &entry : entries_) {
      if (entry.resource_id == resource_id && entry.owner_id == caller_owner &&
          entry.released && !entry.quarantined) {
        return true;
      }
    }
    ++forbidden_delete_attempts_;
    latch_failure("duplicate_or_unowned_release", "OWNERSHIP_UNKNOWN", true);
    return false;
  }

  OfflineVerdict settle() noexcept {
    if (settled_) return verdict_;
    // Missing time or missing owned-release evidence must never report PASS.
    if (!clock_started_) mark_observation_lost();
    if (entries_.empty() && clock_started_)
      latch_failure("resource_observation_invalid", "ARTIFACT_INVALID", false);
    settled_ = true;
    for (const auto &entry : entries_) {
      if (entry.kind == ResourceKind::kProcessHandle &&
          !entry.process_exit_verified) {
        unknown_ = true;
      }
      if (!entry.released || entry.quarantined) {
        unknown_ = true;
      }
    }
    if (in_flight_sync_calls_ > 0 || observation_lost_ ||
        still_owned_count_ > 0 || quarantined_count_ > 0) {
      unknown_ = true;
    }
    if (duplicate_release_attempts_ > 0 || unowned_release_attempts_ > 0 ||
        forbidden_delete_attempts_ > 0) {
      verdict_ = OfflineVerdict::kFail;
    } else if (unknown_) {
      verdict_ = OfflineVerdict::kUnknown;
    } else if (stopped_ || deadline_exceeded_ ||
               first_failure_code_ != std::string("NONE")) {
      verdict_ = OfflineVerdict::kFail;
    } else {
      verdict_ = OfflineVerdict::kPass;
    }
    return verdict_;
  }

  TrialKind trial() const noexcept { return trial_; }
  unsigned acquired() const noexcept { return acquired_count_; }
  unsigned released() const noexcept { return released_count_; }
  unsigned still_owned() const noexcept { return still_owned_count_; }
  unsigned quarantined() const noexcept { return quarantined_count_; }
  unsigned release_attempts() const noexcept { return release_attempts_; }
  unsigned duplicate_releases() const noexcept {
    return duplicate_release_attempts_;
  }
  unsigned unowned_releases() const noexcept {
    return unowned_release_attempts_;
  }
  unsigned forbidden_deletes() const noexcept {
    return forbidden_delete_attempts_;
  }
  unsigned in_flight_sync_calls() const noexcept {
    return in_flight_sync_calls_;
  }
  bool unknown() const noexcept { return unknown_; }
  bool stopped() const noexcept { return stopped_; }
  bool deadline_exceeded() const noexcept { return deadline_exceeded_; }
  OfflineVerdict verdict() const noexcept { return verdict_; }
  const char *failure_code() const noexcept { return first_failure_code_; }

 private:
  void latch_failure(const char *stage, const char *code,
                     bool is_unknown) noexcept {
    if (is_unknown) unknown_ = true;
    if (std::strcmp(first_failure_code_, "NONE") == 0) {
      first_failure_stage_ = stage;
      first_failure_code_ = code;
    }
  }

  TrialKind trial_;
  std::vector<OwnedResourceEntry> entries_;
  uint64_t start_ms_ = 0, last_ms_ = 0;
  unsigned acquired_count_ = 0;
  unsigned released_count_ = 0;
  unsigned still_owned_count_ = 0;
  unsigned quarantined_count_ = 0;
  unsigned release_attempts_ = 0;
  unsigned duplicate_release_attempts_ = 0;
  unsigned unowned_release_attempts_ = 0;
  unsigned forbidden_delete_attempts_ = 0;
  unsigned in_flight_sync_calls_ = 0;
  bool clock_started_ = false;
  bool stopped_ = false;
  bool deadline_exceeded_ = false;
  bool observation_lost_ = false;
  bool unknown_ = false;
  bool settled_ = false;
  const char *first_failure_stage_ = "none";
  const char *first_failure_code_ = "NONE";
  OfflineVerdict verdict_ = OfflineVerdict::kNotRun;
};

// ============================================================================
// B1-C: L1-OBJECTS Restricted Diagnostic Candidate (60s, Isolated Root)
// ============================================================================

struct ObjectsBudget {
  static constexpr unsigned kMaxAppAcquire = 1;
  static constexpr unsigned kMaxCompetingAcquire = 1;
  static constexpr unsigned kMaxBridgeAcquire = 1;
  static constexpr unsigned kMaxObservePerObject = 2;
  static constexpr unsigned kMaxNewPublish = 1;
  static constexpr unsigned kMaxReplace = 1;
  static constexpr unsigned kMaxReadback = 2;
  static constexpr uint64_t kMaxDurationMs = 60000;
};

struct ApprovedObjectPin {
  std::string object_id;
  uint64_t expected_volume = 0;
  uint64_t expected_file_id = 0;
  bool is_directory = false;
  bool check_dacl = true;
  unsigned observations = 0;
  bool security_observed = false;
};

// Isolated root path check: must be an explicit C:\ path, NEVER borrowing the
// production ShirohaQuiz LocalAppData root or any Host A historical path.
inline bool valid_isolated_l1_root(const std::string &path) noexcept {
  if (path.size() < 8 || path.size() > 240 || path.compare(0, 3, "C:\\") != 0 ||
      path.back() == '\\' || path.find("..") != std::string::npos)
    return false;
  for (size_t i = 3; i < path.size(); ++i) {
    char c = path[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '\\'))
      return false;
    if (c == '\\' && path[i - 1] == '\\') return false;
  }
  // Reject production AppData / ShirohaQuiz and Host A paths (case-insensitive)
  std::string lower = path;
  for (char &c : lower) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  if (lower.find("appdata") != std::string::npos ||
      lower.find("shirohaquiz") != std::string::npos ||
      lower.find("host_a") != std::string::npos ||
      lower.find("host-a") != std::string::npos ||
      lower.find("hosta") != std::string::npos) {
    return false;
  }
  return true;
}

// Explicitly approved isolated-root identity. The path string above is only a
// supplementary blacklist: isolation is enforced by binding the injected native
// seam's OWN root handle to this identity before any protected object opens.
// A production or Host A seam therefore fails even with a plausible path text.
struct ApprovedRootPin {
  std::string directory;
  uint64_t volume = 0;
  uint64_t file = 0;
  bool complete() const noexcept {
    return valid_isolated_l1_root(directory) && volume && file;
  }
};

// One-shot probe of the seam root. Creates nothing, never retries a close, and
// returns the opened handle only on success so exactly one Owner can close it.
// SHIROHA_NATIVE_COMMIT_UNKNOWN means the probe handle's custody is unknown.
inline int32_t probe_isolated_root(shiroha_native::ObjectOperations &ops,
                                   const shiroha_native::Sid &sid,
                                   shiroha_native::ObjectInfo &info,
                                   HANDLE &handle) noexcept {
  handle = nullptr;
  if (sid.empty()) return SHIROHA_NATIVE_INVALID_INPUT;
  HANDLE opened = nullptr;
  const int32_t open_rc = ops.local_directory(opened);
  if (open_rc != SHIROHA_NATIVE_OK) return open_rc;
  if (!opened || opened == INVALID_HANDLE_VALUE)
    return SHIROHA_NATIVE_UNAVAILABLE;
  shiroha_native::ObjectInfo observed{};
  const int32_t inspect_rc = ops.inspect(opened, observed);
  if (inspect_rc != SHIROHA_NATIVE_OK ||
      !shiroha_native::object_valid(observed, sid, true, true, true)) {
    if (!ops.close(opened)) return SHIROHA_NATIVE_COMMIT_UNKNOWN;
    return inspect_rc != SHIROHA_NATIVE_OK ? inspect_rc
                                           : SHIROHA_NATIVE_UNAVAILABLE;
  }
  handle = opened;
  info = observed;
  return SHIROHA_NATIVE_OK;
}

// B1-C publishes/readback one explicitly approved App object kind. Kinds 1/2
// are the only credential objects in scope; association (3) and Bridge (4)
// belong to L1-STORE and are rejected instead of being silently substituted.
inline bool valid_app_publish_kind(uint32_t kind) noexcept {
  return kind == 1 || kind == 2;
}

class B1ObjectsDiagnostic {
 public:
  B1ObjectsDiagnostic(const ApprovedRootPin &root_pin,
                      const shiroha_native::Sid &approved_sid,
                      shiroha_native::ObjectOperations &ops,
                      uint32_t publish_kind,
                      TrialKind grant_trial = TrialKind::kObjects)
      : root_pin_(root_pin),
        approved_sid_(approved_sid),
        ops_(ops),
        publish_kind_(publish_kind),
        objects_(ops, shiroha_native::ProtectedObjects::OpenMode::initialize),
        grant_trial_(grant_trial),
        release_(grant_trial) {}

  B1ObjectsDiagnostic(const B1ObjectsDiagnostic &) = delete;
  B1ObjectsDiagnostic &operator=(const B1ObjectsDiagnostic &) = delete;

  bool begin(uint64_t start_ms) noexcept {
    if (started_) return false;
    started_ = true;
    start_ms_ = last_ms_ = start_ms;
    release_.begin_window(start_ms);
    if (!operation_allowed_for_trial(grant_trial_,
                                     OperationDomain::kObjectsLockAndPublish)) {
      return fail("UNAUTHORIZED_ACCESS", OfflineVerdict::kFail);
    }
    if (!valid_isolated_l1_root(root_pin_.directory) || approved_sid_.empty() ||
        !root_pin_.complete() || !valid_app_publish_kind(publish_kind_)) {
      return fail("ADMISSION_BLOCKED", OfflineVerdict::kInconclusive);
    }
    return bind_isolated_root();
  }

  bool register_approved_object(const std::string &object_id,
                                uint64_t expected_volume,
                                uint64_t expected_file_id, bool is_directory,
                                bool check_dacl = true) {
    if (!started_ || stopped_ || !safe_id(object_id) || !expected_volume ||
        !expected_file_id)
      return false;
    if (!check_dacl) {
      return fail("UNAUTHORIZED_ACCESS", OfflineVerdict::kFail);
    }
    for (const auto &item : approved_objects_) {
      if (item.object_id == object_id) return false;
    }
    approved_objects_.push_back(
        {object_id, expected_volume, expected_file_id, is_directory, check_dacl,
         0});
    return true;
  }

  // 1. App acquire (runtime.lock owner = role 1): max 1
  bool acquire_app_lock(uint64_t now_ms) noexcept {
    if (!check_gate(now_ms)) return false;
    if (app_acquire_attempts_ >= ObjectsBudget::kMaxAppAcquire) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++app_acquire_attempts_;
    uint64_t tok = 0;
    const int32_t rc = objects_.acquire(SHIROHA_NATIVE_ABI_VERSION, 1, &tok);
    if (rc != SHIROHA_NATIVE_OK || !tok) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    app_token_ = tok;
    return release_.register_acquired(1001, "app-runtime-lock-owner",
                                      ResourceKind::kProtectedLockLease);
  }

  // 2. Competing App acquire on runtime.lock: max 1, expected denial!
  bool attempt_competing_app_lock(uint64_t now_ms) noexcept {
    if (!check_gate(now_ms)) return false;
    if (competing_acquire_attempts_ >= ObjectsBudget::kMaxCompetingAcquire) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++competing_acquire_attempts_;
    uint64_t competing_tok = 0;
    const int32_t rc =
        objects_.acquire(SHIROHA_NATIVE_ABI_VERSION, 1, &competing_tok);
    if (rc == SHIROHA_NATIVE_OK || competing_tok != 0) {
      if (competing_tok) {
        objects_.close(SHIROHA_NATIVE_ABI_VERSION, competing_tok);
      }
      return fail("SECURITY_REJECT_MISMATCH", OfflineVerdict::kFail);
    }
    competing_denied_ = (rc == SHIROHA_NATIVE_UNAVAILABLE);
    if (!competing_denied_) {
      return fail("SECURITY_REJECT_MISMATCH", OfflineVerdict::kFail);
    }
    return true;
  }

  // 3. Bridge acquire (bridge/client.lock owner = role 2): max 1
  bool acquire_bridge_lock(uint64_t now_ms) noexcept {
    if (!check_gate(now_ms)) return false;
    if (bridge_acquire_attempts_ >= ObjectsBudget::kMaxBridgeAcquire) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++bridge_acquire_attempts_;
    uint64_t tok = 0;
    const int32_t rc = objects_.acquire(SHIROHA_NATIVE_ABI_VERSION, 2, &tok);
    if (rc != SHIROHA_NATIVE_OK || !tok || tok == app_token_) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    bridge_token_ = tok;
    return release_.register_acquired(1002, "bridge-client-lock-owner",
                                      ResourceKind::kProtectedLockLease);
  }

  // 4. Per-object security & identity observation: max 2 per approved object.
  // Verifies NTFS volume/file ID, Owner SID, protected single-ACE DACL,
  // no reparse point, link count == 1, and parent directory identity pin.
  bool observe_object_security(
      uint64_t now_ms, const std::string &object_id, HANDLE handle,
      const shiroha_native::ObjectInfo &parent_pin,
      uint64_t expected_parent_volume,
      uint64_t expected_parent_file_id) noexcept {
    if (!check_gate(now_ms)) return false;
    ApprovedObjectPin *pin = nullptr;
    for (auto &item : approved_objects_) {
      if (item.object_id == object_id) {
        pin = &item;
        break;
      }
    }
    if (!pin) {
      return fail("UNAUTHORIZED_ACCESS", OfflineVerdict::kFail);
    }
    if (pin->observations >= ObjectsBudget::kMaxObservePerObject) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++pin->observations;
    ++total_observations_;

    // Verify parent directory identity & no reparse point on parent
    if (parent_pin.volume != expected_parent_volume ||
        parent_pin.file != expected_parent_file_id ||
        (parent_pin.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        !shiroha_native::object_valid(parent_pin, approved_sid_, true, true,
                                      true)) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }

    shiroha_native::ObjectInfo info{};
    if (ops_.inspect(handle, info) != SHIROHA_NATIVE_OK) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if ((info.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        info.volume != pin->expected_volume ||
        info.file != pin->expected_file_id ||
        (!pin->is_directory && info.links != 1u) ||
        !shiroha_native::object_valid(info, approved_sid_, pin->is_directory,
                                      true, true)) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    pin->security_observed = true;
    return true;
  }

  // 5. Controlled new-target publication (1 max) + first readback
  bool publish_new_target(uint64_t now_ms, const std::vector<uint8_t> &payload,
                          std::vector<uint8_t> &readback_out) noexcept {
    if (!check_gate(now_ms)) return false;
    if (new_publish_attempts_ >= ObjectsBudget::kMaxNewPublish ||
        readback_attempts_ >= ObjectsBudget::kMaxReadback) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    if (!app_token_ || payload.empty()) {
      return fail("ADMISSION_BLOCKED", OfflineVerdict::kFail);
    }
    ++new_publish_attempts_;
    uint8_t scratch[64]{};
    uint64_t needed = 0, ticket = 0;
    const int32_t begin_rc = objects_.credential_begin(
        SHIROHA_NATIVE_ABI_VERSION, app_token_, publish_kind_, scratch,
        sizeof(scratch), &needed, &ticket);
    if (begin_rc != SHIROHA_NATIVE_MISSING || !ticket) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    const int32_t commit_rc = objects_.credential_commit(
        SHIROHA_NATIVE_ABI_VERSION, app_token_, ticket, payload.data(),
        payload.size());
    if (commit_rc == SHIROHA_NATIVE_COMMIT_UNKNOWN) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (commit_rc != SHIROHA_NATIVE_OK) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    return perform_readback(now_ms, payload, readback_out);
  }

  // 6. Controlled replacement of existing target (1 max) + second readback
  bool replace_existing_target(uint64_t now_ms,
                               const std::vector<uint8_t> &expected_previous,
                               const std::vector<uint8_t> &replacement,
                               std::vector<uint8_t> &readback_out) noexcept {
    if (!check_gate(now_ms)) return false;
    if (replace_attempts_ >= ObjectsBudget::kMaxReplace ||
        readback_attempts_ >= ObjectsBudget::kMaxReadback) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    if (!app_token_ || replacement.empty()) {
      return fail("ADMISSION_BLOCKED", OfflineVerdict::kFail);
    }
    ++replace_attempts_;
    std::vector<uint8_t> current(expected_previous.size() + 64);
    uint64_t written = 0, ticket = 0;
    const int32_t begin_rc = objects_.credential_begin(
        SHIROHA_NATIVE_ABI_VERSION, app_token_, publish_kind_, current.data(),
        current.size(), &written, &ticket);
    if (begin_rc != SHIROHA_NATIVE_OK || !ticket) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    current.resize(static_cast<size_t>(written));
    if (current != expected_previous) {
      objects_.credential_abort(SHIROHA_NATIVE_ABI_VERSION, app_token_, ticket);
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    const int32_t commit_rc = objects_.credential_commit(
        SHIROHA_NATIVE_ABI_VERSION, app_token_, ticket, replacement.data(),
        replacement.size());
    if (commit_rc == SHIROHA_NATIVE_COMMIT_UNKNOWN) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (commit_rc != SHIROHA_NATIVE_OK) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    return perform_readback(now_ms, replacement, readback_out);
  }

  // Normal single release per owned lock lease (runtime.lock and client.lock).
  bool release_locks_and_settle(uint64_t now_ms) noexcept {
    if (!started_ || settled_) return false;
    // A deadline latches the failure but never cancels the single legal release
    // attempt or the settlement record.
    check_time(now_ms);
    if (app_token_) {
      const int32_t rc = objects_.close(SHIROHA_NATIVE_ABI_VERSION, app_token_);
      release_.release_once(1001, "app-runtime-lock-owner",
                            rc == SHIROHA_NATIVE_OK);
      app_token_ = 0;
    }
    if (bridge_token_) {
      const int32_t rc =
          objects_.close(SHIROHA_NATIVE_ABI_VERSION, bridge_token_);
      release_.release_once(1002, "bridge-client-lock-owner",
                            rc == SHIROHA_NATIVE_OK);
      bridge_token_ = 0;
    }
    const auto rel_verdict = release_.settle();
    settled_ = true;
    if (rel_verdict == OfflineVerdict::kUnknown ||
        verdict_ == OfflineVerdict::kUnknown) {
      verdict_ = OfflineVerdict::kUnknown;
      if (std::strcmp(failure_code_, "NONE") == 0)
        failure_code_ = "SETTLEMENT_UNKNOWN";
      return false;
    }
    if (stopped_ || rel_verdict != OfflineVerdict::kPass) {
      if (verdict_ == OfflineVerdict::kNotRun) verdict_ = OfflineVerdict::kFail;
      return false;
    }
    bool all_objects_observed = !approved_objects_.empty();
    for (const auto &pin : approved_objects_) {
      if (!pin.security_observed) all_objects_observed = false;
    }
    if (all_objects_observed && app_acquire_attempts_ == 1 &&
        competing_acquire_attempts_ == 1 && competing_denied_ &&
        bridge_acquire_attempts_ == 1 && new_publish_attempts_ == 1 &&
        replace_attempts_ == 1 && readback_attempts_ == 2) {
      if (verdict_ != OfflineVerdict::kNotRun) return false;
      verdict_ = OfflineVerdict::kPass;
      return true;
    }
    verdict_ = OfflineVerdict::kFail;
    return false;
  }

  OfflineVerdict verdict() const noexcept { return verdict_; }
  const char *failure_code() const noexcept { return failure_code_; }
  const B1ReleaseLedger &release_ledger() const noexcept { return release_; }
  unsigned app_acquires() const noexcept { return app_acquire_attempts_; }
  unsigned competing_acquires() const noexcept {
    return competing_acquire_attempts_;
  }
  unsigned bridge_acquires() const noexcept { return bridge_acquire_attempts_; }
  unsigned observations() const noexcept { return total_observations_; }
  unsigned new_publishes() const noexcept { return new_publish_attempts_; }
  unsigned replacements() const noexcept { return replace_attempts_; }
  unsigned readbacks() const noexcept { return readback_attempts_; }

 private:
  // The injected seam must be rooted at the approved isolated root. Path text
  // alone never proves isolation; the probed identity does. The probe handle is
  // its own Owner and receives exactly one close attempt.
  bool bind_isolated_root() noexcept {
    shiroha_native::ObjectInfo root{};
    HANDLE handle = nullptr;
    const int32_t rc = probe_isolated_root(ops_, approved_sid_, root, handle);
    if (rc == SHIROHA_NATIVE_COMMIT_UNKNOWN) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (rc != SHIROHA_NATIVE_OK) {
      return fail("ISOLATION_ROOT_MISMATCH", OfflineVerdict::kFail);
    }
    if (!release_.register_acquired(1000, "isolated-root-prober",
                                    ResourceKind::kProtectedLockLease)) {
      // The probe handle cannot be tracked; close it once without a retry.
      if (!ops_.close(handle)) release_.mark_observation_lost();
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    if (!release_.release_once(1000, "isolated-root-prober",
                               ops_.close(handle))) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (root.volume != root_pin_.volume || root.file != root_pin_.file) {
      return fail("ISOLATION_ROOT_MISMATCH", OfflineVerdict::kFail);
    }
    return true;
  }

  bool perform_readback(uint64_t now_ms, const std::vector<uint8_t> &expected,
                        std::vector<uint8_t> &out) noexcept {
    if (!check_gate(now_ms)) return false;
    if (readback_attempts_ >= ObjectsBudget::kMaxReadback) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++readback_attempts_;
    out.assign(expected.size() + 64, 0);
    uint64_t written = 0, ticket = 0;
    const int32_t begin_rc = objects_.credential_begin(
        SHIROHA_NATIVE_ABI_VERSION, app_token_, publish_kind_, out.data(),
        out.size(), &written, &ticket);
    if (begin_rc != SHIROHA_NATIVE_OK || !ticket) {
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    out.resize(static_cast<size_t>(written));
    const int32_t abort_rc =
        objects_.credential_abort(SHIROHA_NATIVE_ABI_VERSION, app_token_, ticket);
    if (abort_rc != SHIROHA_NATIVE_OK || out != expected) {
      return fail("ARTIFACT_INVALID", OfflineVerdict::kFail);
    }
    return true;
  }

  bool check_time(uint64_t now_ms) noexcept {
    if (now_ms < last_ms_) {
      return fail("MEASUREMENT_UNAVAILABLE", OfflineVerdict::kInconclusive);
    }
    last_ms_ = now_ms;
    if (now_ms - start_ms_ >= ObjectsBudget::kMaxDurationMs) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    return true;
  }

  bool check_gate(uint64_t now_ms) noexcept {
    if (!started_ || stopped_ || settled_) return false;
    return check_time(now_ms);
  }

  bool fail(const char *code, OfflineVerdict v) noexcept {
    stopped_ = true;
    release_.request_stop("supervisor_stop", code);
    if (std::strcmp(failure_code_, "NONE") == 0) failure_code_ = code;
    if (verdict_ == OfflineVerdict::kNotRun || v == OfflineVerdict::kUnknown) {
      verdict_ = v;
    }
    return false;
  }

  ApprovedRootPin root_pin_;
  shiroha_native::Sid approved_sid_;
  shiroha_native::ObjectOperations &ops_;
  uint32_t publish_kind_;
  shiroha_native::ProtectedObjects objects_;
  TrialKind grant_trial_;
  B1ReleaseLedger release_;
  std::vector<ApprovedObjectPin> approved_objects_;
  uint64_t start_ms_ = 0, last_ms_ = 0;
  uint64_t app_token_ = 0, bridge_token_ = 0;
  unsigned app_acquire_attempts_ = 0;
  unsigned competing_acquire_attempts_ = 0;
  unsigned bridge_acquire_attempts_ = 0;
  unsigned total_observations_ = 0;
  unsigned new_publish_attempts_ = 0;
  unsigned replace_attempts_ = 0;
  unsigned readback_attempts_ = 0;
  bool started_ = false, stopped_ = false, settled_ = false;
  bool competing_denied_ = false;
  const char *failure_code_ = "NONE";
  OfflineVerdict verdict_ = OfflineVerdict::kNotRun;
};

// ============================================================================
// B1-D: L1-STORE Restricted Diagnostic Candidate (60s, Single Kind + Ledger)
// ============================================================================

struct StoreBudget {
  static constexpr unsigned kMaxProtect = 2;
  static constexpr unsigned kMaxUnprotect = 2;
  static constexpr size_t kMaxPayloadBytes = 65536;
  // The ABI-3 buffer ceiling is exactly 65536 bytes, so a maximum-size
  // plaintext can never be protected: DPAPI framing needs its own room inside
  // that fixed buffer. The realizable plaintext ceiling is therefore lower by
  // the reserved framing allowance and is never silently relaxed by a Fake
  // transform.
  static constexpr size_t kDpapiFramingReserveBytes = 512;
  static constexpr size_t kMaxPlaintextBytes =
      kMaxPayloadBytes - kDpapiFramingReserveBytes;
  static constexpr unsigned kMaxBegin = 3;
  static constexpr unsigned kMaxCommit = 2;
  static constexpr unsigned kMaxAbort = 1;
  static constexpr uint64_t kMaxDurationMs = 60000;
};

// Expands upper-level Store operations into an auditable primitive call ledger.
struct StorePrimitiveLedger {
  CallCounts owner_acquire{};
  CallCounts owner_validate{};
  CallCounts owner_close{};
  CallCounts dpapi_protect{};
  CallCounts dpapi_unprotect{};
  CallCounts store_begin{};
  CallCounts store_commit{};
  CallCounts store_abort{};
  unsigned total_abi_attempts = 0;
  unsigned temporaries_created_sequential = 0;
  unsigned temporaries_live = 0;
  unsigned max_temporaries_live = 0;
  unsigned memory_zeroed_buffers = 0;
};

inline bool valid_single_store_kind(uint32_t kind) noexcept {
  return kind >= 1 && kind <= 4;
}

inline uint32_t required_role_for_store_kind(uint32_t kind) noexcept {
  return kind == 4 ? 2u : 1u;
}

class B1StoreDiagnostic {
 public:
  // Single store_kind must be explicitly selected for the batch (1, 2, 3, or 4).
  // Passing multiple kinds (e.g. bundling App 1/2/3 and Bridge 4) is rejected.
  B1StoreDiagnostic(const ApprovedRootPin &root_pin,
                    const shiroha_native::Sid &approved_sid,
                    uint32_t selected_store_kind,
                    unsigned bundled_kind_count,
                    const shiroha_native::Operations &dpapi_ops,
                    shiroha_native::ObjectOperations &object_ops,
                    TrialKind grant_trial = TrialKind::kStore)
      : root_pin_(root_pin),
        approved_sid_(approved_sid),
        selected_kind_(selected_store_kind),
        bundled_kind_count_(bundled_kind_count),
        dpapi_ops_(dpapi_ops),
        object_ops_(object_ops),
        objects_(object_ops,
                 shiroha_native::ProtectedObjects::OpenMode::initialize),
        grant_trial_(grant_trial),
        release_(grant_trial) {}

  B1StoreDiagnostic(const B1StoreDiagnostic &) = delete;
  B1StoreDiagnostic &operator=(const B1StoreDiagnostic &) = delete;

  bool begin(uint64_t start_ms) noexcept {
    if (started_) return false;
    started_ = true;
    start_ms_ = last_ms_ = start_ms;
    release_.begin_window(start_ms);
    if (!operation_allowed_for_trial(
            grant_trial_, OperationDomain::kStoreDpapiAndTransaction)) {
      return fail("UNAUTHORIZED_ACCESS", OfflineVerdict::kFail);
    }
    // Reject missing/invalid Store kind or bundling multiple kinds in one batch
    if (!valid_isolated_l1_root(root_pin_.directory) || !root_pin_.complete() ||
        !valid_single_store_kind(selected_kind_) || bundled_kind_count_ != 1u) {
      return fail("ADMISSION_BLOCKED", OfflineVerdict::kFail);
    }
    if (!bind_isolated_root()) return false;
    const uint32_t role = required_role_for_store_kind(selected_kind_);
    ++ledger_.owner_acquire.attempted;
    ++ledger_.total_abi_attempts;
    uint64_t tok = 0;
    const int32_t rc = objects_.acquire(SHIROHA_NATIVE_ABI_VERSION, role, &tok);
    ++ledger_.owner_acquire.returned;
    if (rc != SHIROHA_NATIVE_OK || !tok) {
      ++ledger_.owner_acquire.returned_failure;
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    ++ledger_.owner_acquire.accepted;
    owner_token_ = tok;
    if (!release_.register_acquired(2001, "store-batch-owner",
                                    ResourceKind::kProtectedLockLease)) {
      // Untracked Owner cannot be settled; close it once without a retry.
      ++ledger_.owner_close.attempted;
      ++ledger_.total_abi_attempts;
      const int32_t close_rc =
          objects_.close(SHIROHA_NATIVE_ABI_VERSION, owner_token_);
      ++ledger_.owner_close.returned;
      if (close_rc == SHIROHA_NATIVE_OK)
        ++ledger_.owner_close.accepted;
      else
        ++ledger_.owner_close.unknown;
      owner_token_ = 0;
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    return true;
  }

  bool dpapi_protect(uint64_t now_ms, uint32_t requested_kind,
                     const std::vector<uint8_t> &plaintext,
                     std::vector<uint8_t> &ciphertext_out) noexcept {
    if (!check_gate(now_ms, requested_kind)) return false;
    if (ledger_.dpapi_protect.attempted >= StoreBudget::kMaxProtect ||
        plaintext.empty() ||
        plaintext.size() > StoreBudget::kMaxPlaintextBytes) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++ledger_.dpapi_protect.attempted;
    ++ledger_.total_abi_attempts;
    ciphertext_out.assign(StoreBudget::kMaxPayloadBytes, 0);
    uint64_t written = 0;
    const int32_t rc = shiroha_native::transform(
        SHIROHA_NATIVE_ABI_VERSION, plaintext.data(), plaintext.size(),
        ciphertext_out.data(), ciphertext_out.size(), &written, false,
        dpapi_ops_);
    ++ledger_.dpapi_protect.returned;
    if (rc != SHIROHA_NATIVE_OK || !written) {
      ++ledger_.dpapi_protect.returned_failure;
      SecureZeroMemory(ciphertext_out.data(), ciphertext_out.size());
      ciphertext_out.clear();
      ++ledger_.memory_zeroed_buffers;
      return fail("ARTIFACT_INVALID", OfflineVerdict::kFail);
    }
    ciphertext_out.resize(static_cast<size_t>(written));
    ++ledger_.dpapi_protect.accepted;
    ++ledger_.dpapi_protect.settled;
    return true;
  }

  bool dpapi_unprotect(uint64_t now_ms, uint32_t requested_kind,
                       const std::vector<uint8_t> &ciphertext,
                       std::vector<uint8_t> &plaintext_out) noexcept {
    if (!check_gate(now_ms, requested_kind)) return false;
    if (ledger_.dpapi_unprotect.attempted >= StoreBudget::kMaxUnprotect ||
        ciphertext.empty() ||
        ciphertext.size() > StoreBudget::kMaxPayloadBytes) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    ++ledger_.dpapi_unprotect.attempted;
    ++ledger_.total_abi_attempts;
    std::vector<uint8_t> scratch(StoreBudget::kMaxPayloadBytes, 0);
    uint64_t written = 0;
    const int32_t rc = shiroha_native::transform(
        SHIROHA_NATIVE_ABI_VERSION, ciphertext.data(), ciphertext.size(),
        scratch.data(), scratch.size(), &written, true, dpapi_ops_);
    ++ledger_.dpapi_unprotect.returned;
    if (rc != SHIROHA_NATIVE_OK || !written ||
        written > StoreBudget::kMaxPayloadBytes) {
      ++ledger_.dpapi_unprotect.returned_failure;
      SecureZeroMemory(scratch.data(), scratch.size());
      ++ledger_.memory_zeroed_buffers;
      return fail("ARTIFACT_INVALID", OfflineVerdict::kFail);
    }
    plaintext_out.assign(scratch.begin(),
                         scratch.begin() + static_cast<size_t>(written));
    SecureZeroMemory(scratch.data(), scratch.size());
    ++ledger_.memory_zeroed_buffers;
    ++ledger_.dpapi_unprotect.accepted;
    ++ledger_.dpapi_unprotect.settled;
    return true;
  }

  int32_t store_begin(uint64_t now_ms, uint32_t requested_kind,
                      std::vector<uint8_t> &existing_out,
                      uint64_t &ticket_out) noexcept {
    ticket_out = 0;
    if (!check_gate(now_ms, requested_kind)) return SHIROHA_NATIVE_INVALID_INPUT;
    if (ledger_.store_begin.attempted >= StoreBudget::kMaxBegin ||
        active_ticket_ != 0) {
      fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
      return SHIROHA_NATIVE_INVALID_INPUT;
    }
    ++ledger_.store_begin.attempted;
    ++ledger_.total_abi_attempts;
    std::vector<uint8_t> buf(StoreBudget::kMaxPayloadBytes, 0);
    uint64_t written = 0, ticket = 0;
    int32_t rc = SHIROHA_NATIVE_UNAVAILABLE;
    if (selected_kind_ == 3) {
      rc = objects_.association_begin(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                      buf.data(), buf.size(), &written,
                                      &ticket);
    } else {
      rc = objects_.credential_begin(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                     selected_kind_, buf.data(), buf.size(),
                                     &written, &ticket);
    }
    ++ledger_.store_begin.returned;
    if ((rc != SHIROHA_NATIVE_OK && rc != SHIROHA_NATIVE_MISSING) || !ticket) {
      ++ledger_.store_begin.returned_failure;
      SecureZeroMemory(buf.data(), buf.size());
      ++ledger_.memory_zeroed_buffers;
      fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
      return rc;
    }
    if (rc == SHIROHA_NATIVE_OK) {
      existing_out.assign(buf.begin(),
                          buf.begin() + static_cast<size_t>(written));
    } else {
      existing_out.clear();
    }
    SecureZeroMemory(buf.data(), buf.size());
    ++ledger_.memory_zeroed_buffers;
    const uint64_t ticket_res = 2100 + ledger_.store_begin.attempted;
    if (!release_.register_acquired(ticket_res, "store-batch-owner",
                                    ResourceKind::kStoreTicket)) {
      // An untracked ticket would bypass settlement; abort it exactly once.
      ++ledger_.store_abort.attempted;
      ++ledger_.total_abi_attempts;
      int32_t abort_rc = SHIROHA_NATIVE_UNAVAILABLE;
      if (selected_kind_ == 3) {
        abort_rc = objects_.association_abort(SHIROHA_NATIVE_ABI_VERSION,
                                              owner_token_, ticket);
      } else {
        abort_rc = objects_.credential_abort(SHIROHA_NATIVE_ABI_VERSION,
                                             owner_token_, ticket);
      }
      ++ledger_.store_abort.returned;
      if (abort_rc == SHIROHA_NATIVE_OK)
        ++ledger_.store_abort.accepted;
      else
        ++ledger_.store_abort.returned_failure;
      fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
      return SHIROHA_NATIVE_UNAVAILABLE;
    }
    active_ticket_ = ticket;
    ticket_out = ticket;
    active_ticket_resource_id_ = ticket_res;
    ++ledger_.store_begin.accepted;
    return rc;
  }

  int32_t store_commit(uint64_t now_ms, uint32_t requested_kind,
                       uint64_t ticket,
                       const std::vector<uint8_t> &payload) noexcept {
    if (!check_gate(now_ms, requested_kind)) return SHIROHA_NATIVE_INVALID_INPUT;
    if (ledger_.store_commit.attempted >= StoreBudget::kMaxCommit ||
        !active_ticket_ || ticket != active_ticket_ || payload.empty() ||
        payload.size() > StoreBudget::kMaxPayloadBytes ||
        ledger_.temporaries_created_sequential >= 2) {
      fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
      return SHIROHA_NATIVE_INVALID_INPUT;
    }
    ++ledger_.store_commit.attempted;
    ++ledger_.total_abi_attempts;
    ++ledger_.temporaries_created_sequential;
    ++ledger_.temporaries_live;
    ledger_.max_temporaries_live =
        (std::max)(ledger_.max_temporaries_live, ledger_.temporaries_live);

    int32_t rc = SHIROHA_NATIVE_UNAVAILABLE;
    if (selected_kind_ == 3) {
      rc = objects_.association_commit(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                       ticket, payload.data(), payload.size());
    } else {
      rc = objects_.credential_commit(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                      ticket, payload.data(), payload.size());
    }
    ++ledger_.store_commit.returned;
    if (ledger_.temporaries_live > 0) --ledger_.temporaries_live;

    const uint64_t ticket_res = active_ticket_resource_id_;
    active_ticket_ = 0;
    active_ticket_resource_id_ = 0;

    if (rc == SHIROHA_NATIVE_COMMIT_UNKNOWN) {
      ++ledger_.store_commit.unknown;
      release_.release_once(ticket_res, "store-batch-owner", false);
      fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
      return rc;
    }
    if (rc != SHIROHA_NATIVE_OK) {
      ++ledger_.store_commit.returned_failure;
      release_.release_once(ticket_res, "store-batch-owner", false);
      fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
      return rc;
    }
    release_.release_once(ticket_res, "store-batch-owner", true);
    ++ledger_.store_begin.settled;
    ++ledger_.store_commit.accepted;
    ++ledger_.store_commit.settled;
    return rc;
  }

  int32_t store_abort(uint64_t now_ms, uint32_t requested_kind,
                      uint64_t ticket) noexcept {
    if (!check_gate(now_ms, requested_kind)) return SHIROHA_NATIVE_INVALID_INPUT;
    if (ledger_.store_abort.attempted >= StoreBudget::kMaxAbort ||
        !active_ticket_ || ticket != active_ticket_) {
      fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
      return SHIROHA_NATIVE_INVALID_INPUT;
    }
    ++ledger_.store_abort.attempted;
    ++ledger_.total_abi_attempts;
    int32_t rc = SHIROHA_NATIVE_UNAVAILABLE;
    if (selected_kind_ == 3) {
      rc = objects_.association_abort(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                      ticket);
    } else {
      rc = objects_.credential_abort(SHIROHA_NATIVE_ABI_VERSION, owner_token_,
                                     ticket);
    }
    ++ledger_.store_abort.returned;
    const uint64_t ticket_res = active_ticket_resource_id_;
    active_ticket_ = 0;
    active_ticket_resource_id_ = 0;
    if (rc != SHIROHA_NATIVE_OK) {
      ++ledger_.store_abort.returned_failure;
      release_.release_once(ticket_res, "store-batch-owner", false);
      fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
      return rc;
    }
    release_.release_once(ticket_res, "store-batch-owner", true);
    ++ledger_.store_begin.settled;
    ++ledger_.store_abort.accepted;
    ++ledger_.store_abort.settled;
    return rc;
  }

  bool close_and_settle(uint64_t now_ms) noexcept {
    if (!started_ || settled_) return false;
    // A deadline latches the failure but never cancels the single legal close
    // or the settlement record.
    check_time(now_ms);
    if (owner_token_) {
      ++ledger_.owner_close.attempted;
      ++ledger_.total_abi_attempts;
      const int32_t rc =
          objects_.close(SHIROHA_NATIVE_ABI_VERSION, owner_token_);
      ++ledger_.owner_close.returned;
      const bool ok = (rc == SHIROHA_NATIVE_OK);
      if (ok) {
        ++ledger_.owner_acquire.settled;
        ++ledger_.owner_close.accepted;
        ++ledger_.owner_close.settled;
      } else {
        ++ledger_.owner_close.unknown;
      }
      release_.release_once(2001, "store-batch-owner", ok);
      owner_token_ = 0;
    }
    const auto rel_verdict = release_.settle();
    settled_ = true;
    if (rel_verdict == OfflineVerdict::kUnknown ||
        verdict_ == OfflineVerdict::kUnknown || ledger_.store_commit.unknown ||
        ledger_.owner_close.unknown) {
      verdict_ = OfflineVerdict::kUnknown;
      if (std::strcmp(failure_code_, "NONE") == 0)
        failure_code_ = "SETTLEMENT_UNKNOWN";
      return false;
    }
    if (stopped_ || rel_verdict != OfflineVerdict::kPass) {
      if (verdict_ == OfflineVerdict::kNotRun) verdict_ = OfflineVerdict::kFail;
      return false;
    }
    if (verdict_ != OfflineVerdict::kNotRun) return false;
    // Attempt ceilings only limit work. PASS additionally requires the full
    // successful candidate: two DPAPI round trips and three transactions
    // settled by two commits and one abort, with the Owner released.
    if (ledger_.owner_acquire.settled != 1 ||
        ledger_.owner_close.settled != 1 ||
        ledger_.dpapi_protect.settled != 2 ||
        ledger_.dpapi_unprotect.settled != 2 ||
        ledger_.store_begin.settled != 3 || ledger_.store_commit.settled != 2 ||
        ledger_.store_abort.settled != 1) {
      return fail("ARTIFACT_INVALID", OfflineVerdict::kFail);
    }
    verdict_ = OfflineVerdict::kPass;
    return true;
  }

  const StorePrimitiveLedger &ledger() const noexcept { return ledger_; }
  const B1ReleaseLedger &release_ledger() const noexcept { return release_; }
  OfflineVerdict verdict() const noexcept { return verdict_; }
  const char *failure_code() const noexcept { return failure_code_; }
  uint32_t selected_kind() const noexcept { return selected_kind_; }

 private:
  // Same seam binding as B1-C: the injected ObjectOperations root must match
  // the approved isolated-root identity, not merely a plausible path string.
  bool bind_isolated_root() noexcept {
    shiroha_native::ObjectInfo root{};
    HANDLE handle = nullptr;
    const int32_t rc =
        probe_isolated_root(object_ops_, approved_sid_, root, handle);
    if (rc == SHIROHA_NATIVE_COMMIT_UNKNOWN) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (rc != SHIROHA_NATIVE_OK) {
      return fail("ISOLATION_ROOT_MISMATCH", OfflineVerdict::kFail);
    }
    if (!release_.register_acquired(2000, "isolated-root-prober",
                                    ResourceKind::kProtectedLockLease)) {
      if (!object_ops_.close(handle)) release_.mark_observation_lost();
      return fail("OWNERSHIP_UNKNOWN", OfflineVerdict::kFail);
    }
    if (!release_.release_once(2000, "isolated-root-prober",
                               object_ops_.close(handle))) {
      return fail("SETTLEMENT_UNKNOWN", OfflineVerdict::kUnknown);
    }
    if (root.volume != root_pin_.volume || root.file != root_pin_.file) {
      return fail("ISOLATION_ROOT_MISMATCH", OfflineVerdict::kFail);
    }
    return true;
  }

  bool check_time(uint64_t now_ms) noexcept {
    if (now_ms < last_ms_) {
      return fail("MEASUREMENT_UNAVAILABLE", OfflineVerdict::kInconclusive);
    }
    last_ms_ = now_ms;
    if (now_ms - start_ms_ >= StoreBudget::kMaxDurationMs) {
      return fail("BUDGET_EXCEEDED", OfflineVerdict::kFail);
    }
    return true;
  }

  bool check_gate(uint64_t now_ms, uint32_t requested_kind) noexcept {
    if (!started_ || stopped_ || settled_) return false;
    if (requested_kind != selected_kind_) {
      return fail("UNAUTHORIZED_ACCESS", OfflineVerdict::kFail);
    }
    return check_time(now_ms);
  }

  bool fail(const char *code, OfflineVerdict v) noexcept {
    stopped_ = true;
    release_.request_stop("supervisor_stop", code);
    if (std::strcmp(failure_code_, "NONE") == 0) failure_code_ = code;
    if (verdict_ == OfflineVerdict::kNotRun || v == OfflineVerdict::kUnknown) {
      verdict_ = v;
    }
    return false;
  }

  ApprovedRootPin root_pin_;
  shiroha_native::Sid approved_sid_;
  uint32_t selected_kind_;
  unsigned bundled_kind_count_;
  const shiroha_native::Operations &dpapi_ops_;
  shiroha_native::ObjectOperations &object_ops_;
  shiroha_native::ProtectedObjects objects_;
  TrialKind grant_trial_;
  B1ReleaseLedger release_;
  StorePrimitiveLedger ledger_{};
  uint64_t start_ms_ = 0, last_ms_ = 0;
  uint64_t owner_token_ = 0, active_ticket_ = 0, active_ticket_resource_id_ = 0;
  bool started_ = false, stopped_ = false, settled_ = false;
  const char *failure_code_ = "NONE";
  OfflineVerdict verdict_ = OfflineVerdict::kNotRun;
};

}  // namespace b1
}  // namespace shiroha_l1_crypto

#endif  // SHIROHA_L1_B1_UNIFIED_H_
