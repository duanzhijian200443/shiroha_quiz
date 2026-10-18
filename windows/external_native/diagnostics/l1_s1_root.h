#ifndef SHIROHA_L1_S1_ROOT_H_
#define SHIROHA_L1_S1_ROOT_H_
#include "diagnostics/l1_r2_adapters.h"

namespace shiroha_l1_crypto::s1 {
// Diagnostic accounting only; no approval parser or new execution authority.
enum Counter : size_t {
  directories,
  files,
  security_reads,
  os_calls,
  root_creates,
  security_sets,
  evidence_creates,
  handles_acquired,
  handles_closed,
  hash_reads,
  hash_bytes,
  evidence_writes,
  evidence_flushes,
  evidence_bytes,
  counter_count
};
using Counts = std::array<uint64_t, counter_count>;
enum class Step {
  identity,
  parent,
  artifact,
  create,
  root,
  evidence_open,
  evidence,
  close
};
Counts cost(Step, size_t evidence_parents = 0);
Counts ceiling(size_t parents, size_t artifacts, size_t evidence_parents);
struct Request {
  r1::Frozen frozen;
  r2::Limits limits; // retains the sole F1 Custodian EXE digest
  std::vector<r1::Pin> parents,
      evidence_parents; // C:\ through immediate parent
  std::string root_id, root_security_sha256, evidence_directory;
  Counts budget{}; // independently selected; no defaults from ceiling()
  bool valid() const;
  std::string hash() const;
};
std::string pin_hash(const r1::Pin &);
// Directory Pins carry no file bytes. Their digest must be the existing R2
// metadata-only derivation of the same Volume/File ID, never a caller label.
std::string metadata_digest(const ObjectIdentityPin &);
std::vector<std::string> parent_paths(const std::string &);
struct Runtime {
  r2::RuntimeFacts facts;
  std::string device_sha256;
};
struct Observation {
  r1::Pin pin;
  bool c_ntfs = false, directory = false, reparse = true, delete_pending = true,
       exact_path = false;
};
enum class Creation { created, exists, denied, unknown };
struct Handoff {
  r1::IoStatus status = r1::IoStatus::kUnknown;
  std::string owner, request, pin;
};
struct Operations {
  virtual ~Operations() = default;
  virtual r1::Origin origin() const noexcept = 0;
  virtual Runtime identity() = 0;
  virtual Observation parent(size_t) = 0;
  virtual bool artifact(size_t, r1::Pin &, uint32_t &read_calls) = 0;
  virtual Creation create_root() = 0;
  virtual Observation root() = 0;
  virtual bool open_evidence() = 0;
  virtual Handoff handoff(const r1::Pin &, const std::string &request) = 0;
  virtual bool close_root() = 0;
  virtual bool close_evidence() = 0;
};
enum class State { rejected, unknown, pinned };
enum class Failure {
  none,
  gate,
  target,
  identity,
  parent,
  artifact,
  budget,
  creation,
  root,
  evidence,
  handoff,
  close
};
struct Result {
  const char *evidence_class = "OFFLINE", *backend = "FAKE";
  State state = State::rejected;
  Failure failure = Failure::none;
  Counts reserved{}; // conservative upper bounds, NOT measured API totals
  uint32_t artifact_read_calls = 0, evidence_attempts = 0;
  bool stopped = false, runtime_denied = false, create_attempted = false,
       created = false, evidence_opened = false, evidence_preserved = false,
       handoff_attempted = false, handoff_acknowledged = false,
       root_close_attempted = false, root_closed = false,
       evidence_close_attempted = false, evidence_closed = false;
  r1::Pin root;
  r1::Record last;
};
class WindowsPreparation;
class Preparation final {
public:
  Preparation(Request, Operations &, r1::EvidenceSink &);
  Preparation(const Preparation &) = delete;
  Preparation &operator=(const Preparation &) = delete;
  bool run_offline(); // admits only an injected Fake, never WindowsApi
  bool close_root_once(const std::string &owner);
  bool close_evidence_once(const std::string &owner);
  const Result &result() const { return result_; }

private:
  friend class WindowsPreparation;
  bool run(r1::Origin);
  bool reserve(Step);
  bool parents();
  bool root();
  bool save(r1::Stage);
  bool fail(Failure, bool unknown = false);
  void finish_failure();
  const Request request_;
  Operations &ops_;
  r1::EvidenceSink &sink_;
  Result result_;
  bool attempted_ = false, sink_failed_ = false;
  r1::Origin origin_ = r1::Origin::kUnavailable;
};
// Concrete, parameter-free denial. CLI/environment/JSON cannot replace it.
inline bool windows_runtime_allowed() noexcept { return false; }
int windows_process_entry(int, wchar_t **) noexcept;
} // namespace shiroha_l1_crypto::s1
#endif
