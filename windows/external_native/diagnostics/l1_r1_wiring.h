#ifndef SHIROHA_L1_R1_WIRING_H_
#define SHIROHA_L1_R1_WIRING_H_

#include "diagnostics/l1_b1_unified.h"

namespace shiroha_l1_crypto {
namespace r1 {

// These ports model a separately surviving creator, NOT a Windows service or
// an authenticated cross-process channel. Only the Fake backend exists.
enum class Origin { kUnavailable, kFake, kWindowsApi, kIndependentBuild };
enum class Stage : uint32_t {
  kControllerStarted,
  kMeasured,
  kCreateIntent,
  kCustodyAccepted,
  kApproval,
  kIssueIntent,
  kIssued,
  kRequestIntent,
  kRequested,
  kBurnIntent,
  kConsumed,
  kJournalIntent,
  kJournalUpdated,
  kCreateAttempt,
  kProcessIdentity,
  kCustodyAcknowledged,
  kResumeAttempt,
  kResumed,
  kIpc,
  kExitObserved,
  kHandlesSettled,
  kRecoveryRequired,
  kFinal
};
enum class IoStatus { kOk, kDenied, kUnknown };
enum class Failure : uint32_t {
  kNone,
  kGate,
  kTarget,
  kMeasurement,
  kCustody,
  kEvidence,
  kBudget,
  kControllerLost,
  kProcess,
  kDeadline,
  kProtocol
};

struct Pin {
  std::string id, owner, security_sha256, bytes_sha256;
  ObjectIdentityPin object, parent;
  bool operator==(const Pin &p) const;
};
struct BuildEvidence {
  Origin origin = Origin::kUnavailable;
  std::string source, base, toolchain, controller, worker, dependencies;
  bool operator==(const BuildEvidence &p) const;
};
struct Measurement {
  Origin origin = Origin::kUnavailable;
  std::string device_sha256, os_sha256, account_sha256;
  std::wstring token_sid; // transient private input; never sent to EvidenceSink
  bool primary_medium = false, non_elevated = false, minimal_privileges = false;
  BuildEvidence build;
  std::vector<Pin> pins;
};
struct Manifest {
  std::string device_sha256, os_sha256, pin_owner, custody_owner,
      evidence_owner;
  BuildEvidence build;
  std::vector<Pin> pins;
  uint32_t max_pumps = 0; // approved numeric value required; hard ceiling 4096
  std::string r2_sha256; // optional R2 policy; empty preserves R1 bytes
  bool valid() const;
  std::string hash() const;
};
struct Frozen {
  e5::FixedTarget target;
  Manifest manifest;
  bool valid() const;
  std::string hash() const;
  bool matches(const Measurement &) const;
};
struct IdentityPort {
  virtual ~IdentityPort() = default;
  // Independent measurement first, comparison second. Labels are not proof.
  virtual Measurement measure() = 0;
  virtual bool close_borrowed_pins_once() = 0;
};
struct ProcessIdentity {
  uint32_t pid = 0;
  uint64_t creation_time = 0;
  std::string image_sha256, account_sha256, target_sha256, owner;
  bool primary_medium = false, non_elevated = false;
  std::string hash() const;
};
struct CustodyReceipt {
  Origin origin = Origin::kUnavailable;
  IoStatus status = IoStatus::kUnknown;
  std::string owner, target_sha256, external_record_sha256;
  bool creator_is_independent = false, owns_process_and_thread = false;
  std::string process_identity_sha256;
};
// The external creator owns create/Resume/process/thread/pipe handles for its
// entire lifetime. Controller never receives a HANDLE or a create fallback.
// Acceptance must be established BEFORE create; post-create PID notification
// cannot satisfy it. A real implementation/trust boundary is still absent.
struct CustodyPort : e4::LaunchSteps {
  virtual CustodyReceipt accept_intent(const Frozen &) = 0;
  virtual ProcessIdentity process_identity() = 0;
  virtual CustodyReceipt acknowledge_identity(const ProcessIdentity &) = 0;
  virtual void controller_lost() noexcept = 0;
  virtual bool approve(const e4::ApprovalPromptModel &,
                       e4::ApprovalUiResponse &) = 0;
  virtual e4::ClockReading read_clock() = 0;
  virtual e5::Observation observe() = 0;
  virtual bool next(e4::Frame &, bool &) = 0;
  virtual bool send(const e4::Frame &) = 0;
  virtual bool close_observed_exit() = 0;
  virtual bool close_owned_io() = 0;
};

// Fixed allowlist of redacted values. No raw logs, SID, path, environment or
// general-purpose string payload can cross this sink interface.
struct Record {
  Stage stage = Stage::kControllerStarted;
  Failure first_failure = Failure::kNone;
  std::string batch, target, manifest, previous, reviewer, verifier;
  std::string review_sha256, verification_sha256, process_identity_sha256;
  uint32_t sequence = 0, pid = 0;
  uint64_t creation_time = 0;
  uint64_t utc_ms = 0, mono_ms = 0, launch_attempt_ms = 0;
  std::array<CallCounts, 7> abi{};
  std::array<CallCounts, kNativeOpCount> native{};
  std::array<ResourceSample, 18> samples{};
  uint32_t sample_count = 0;
  ResourceSample controller_peak{};
  bool approved = false, consumed = false, created = false, resumed = false;
  bool creation_unknown = false, deadline_exceeded = false,
       ipc_complete = false;
  StopReason first_stop = StopReason::kNone;
  bool custody_accepted = false, custody_acknowledged = false;
  bool exited = false, handles_closed = false, recovery_required = false;
  OfflineVerdict security = OfflineVerdict::kNotRun;
  OfflineVerdict stability = OfflineVerdict::kNotRun;
  std::string hash() const;
};
struct SinkReceipt {
  Origin origin = Origin::kUnavailable;
  IoStatus status = IoStatus::kUnknown;
  uint32_t sequence = 0;
  std::string record_sha256;
};
struct EvidenceSink {
  virtual ~EvidenceSink() = default;
  // One bounded append+integrity/retention acknowledgment per sequence. No
  // retry on denied/UNKNOWN, no receipt inferred from a completed Write/Flush.
  // Fake persistence remains OFFLINE, never LOCAL-L1 durability evidence.
  virtual SinkReceipt preserve(const Record &) = 0;
};
struct Result {
  const char *evidence_class = "OFFLINE", *backend = "FAKE";
  e5::Evidence core;
  b1::AdmissionPhaseLedger phases;
  Record last;
  Failure first_failure = Failure::kNone;
  bool terminal = false, evidence_preserved = false, runtime_denied = false;
  uint32_t writes_attempted = 0, pumps = 0;
};

class Composition;
struct WorkerInvocation {
  Frozen frozen;
  e4::WorkerLink *link = nullptr;
  uint32_t pid = 0;
  bool (*clock)(uint64_t &) noexcept = nullptr;
  std::array<uint64_t, 2> inherited_pipe_tokens{};
};
struct EntryPort {
  virtual ~EntryPort() = default;
  virtual Origin origin() const noexcept = 0;
  virtual Composition *attach_controller() noexcept = 0;
  virtual bool attach_worker(WorkerInvocation &) = 0;
};
// Concrete entry capability has no opt-in, parameters or build-time override.
class ClosedWindowsBoundary final : public EntryPort {
public:
  bool allow_live_execution() const noexcept { return false; }
  Origin origin() const noexcept override { return Origin::kUnavailable; }
  Composition *attach_controller() noexcept override { return nullptr; }
  bool attach_worker(WorkerInvocation &) override { return false; }
};
int controller_process_entry(int, wchar_t **, EntryPort &) noexcept;
int worker_process_entry(int, wchar_t **, EntryPort &) noexcept;
// Worker target is supplied AFTER artifact hashing by the fixed composition,
// not compiled into its own EXE. Two handle values are transport data only.
bool worker_main(const Frozen &, e4::WorkerLink &, uint32_t,
                 bool (*clock)(uint64_t &) noexcept);

class Composition final : private e5::Platform, private e4::GrantIo {
public:
  Composition(Frozen, e4::GrantIo &, IdentityPort &, CustodyPort &,
              EvidenceSink &);
  Composition(const Composition &) = delete;
  Composition &operator=(const Composition &) = delete;
  bool begin() noexcept;
  bool pump() noexcept;
  void controller_lost() noexcept;
  Result result() const { return result_; }

private:
  bool runtime_allowed() const noexcept override { return offline_ready_; }
  bool inspect_target(const e5::FixedTarget &) override;
  bool approve(const e4::ApprovalPromptModel &,
               e4::ApprovalUiResponse &) override;
  e4::ClockReading read_clock() override;
  e4::WorkerStart start_suspended(const GrantTarget &, const e4::Digest &,
                                  e4::ClockReading) override;
  e5::Observation observe() override;
  bool next(e4::Frame &, bool &) override;
  bool send(const e4::Frame &) override;
  bool close_observed_exit() override;
  bool close_owned_io() override;
  void handoff(const std::string &, uint32_t) noexcept override;
  bool principal(const std::wstring &) override;
  e4::IoResult issue_new(const e4::Receipt &, BatchObjectPins &) override;
  bool inspect(const BatchObjectPins &) override;
  e4::IoResult request_new(const e4::Journal &) override;
  e4::IoResult burn_issued() override;
  e4::IoResult update_request(const e4::Journal &) override;
  bool save(Stage);
  void capture();
  void fail(Failure) noexcept;
  bool receipt_ok(const CustodyReceipt &, bool handles) const;
  void finish() noexcept;
  const Frozen frozen_;
  e4::GrantIo &io_;
  IdentityPort &identity_;
  CustodyPort &custody_;
  EvidenceSink &sink_;
  b1::UnifiedAdmissionController controller_;
  Result result_;
  ProcessIdentity process_;
  bool attempted_ = false, offline_ready_ = false, create_attempted_ = false;
  bool pins_close_attempted_ = false, lost_ = false, sink_failed_ = false;
  bool exit_observed_ = false;
  uint32_t measurements_ = 0, clocks_ = 0, observations_ = 0, nexts_ = 0,
           sends_ = 0;
  uint32_t record_inspections_ = 0;
};
} // namespace r1
} // namespace shiroha_l1_crypto
#endif
