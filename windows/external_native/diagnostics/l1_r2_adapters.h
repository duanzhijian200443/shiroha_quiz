#ifndef SHIROHA_L1_R2_ADAPTERS_H_
#define SHIROHA_L1_R2_ADAPTERS_H_
#include "diagnostics/l1_r1_wiring.h"

namespace shiroha_l1_crypto::r2 {
// Source ceilings, never an approved resource limit or an execution capability.
inline constexpr uint32_t kPolls = 512, kUiEvents = 128, kPins = 64,
                          kParents = 16, kDependencies = 32;
inline constexpr size_t kArtifactBytes = 16 * 1024 * 1024,
                        kReadBlock = 65536, kRecordBytes = 8192;
enum class Role : uint32_t { controller, custodian, worker };
struct ResourceLimit {
  uint64_t working = 0, commit = 0;
  uint32_t handles = 0;
  bool valid() const { return working && commit && handles; }
};
struct Limits {
  std::string custodian_sha256, channel_sha256;
  std::array<ResourceLimit, 3> process{};
  uint32_t polls = 0, poll_ms = 0, ui_events = 0;
  uint64_t approval_ms = 0, handoff_ms = 0;
  bool valid() const;
  std::string hash() const;
};
// Independent physical observations; caller assertions never become OS proof.
struct RuntimeFacts {
  r1::Origin origin = r1::Origin::kUnavailable;
  uint32_t major = 0, minor = 0, build = 0, revision = 0, edition = 0;
  bool x64 = false, primary_medium = false, non_elevated = false;
  uint32_t pid = 0;
  uint64_t creation_time = 0;
  std::wstring sid; // transient, excluded from all records
  std::string account, os;
};
struct ReadPort {
  virtual ~ReadPort() = default;
  virtual bool size(uint64_t &) = 0;
  virtual bool rewind() = 0;
  virtual bool read(uint8_t *, size_t requested, size_t &returned) = 0;
};
// Short artifact reads STOP immediately; they do not create a per-byte loop.
bool bounded_hash(ReadPort &, std::string &hash, uint32_t &reads);

enum class WriteStatus { ok, denied, unknown };
struct PersistencePort {
  virtual ~PersistencePort() = default;
  virtual r1::Origin origin() const noexcept = 0;
  virtual bool inspect_destination() = 0;
  // CREATE_NEW/opening is separate from append; exactly one write and Flush
  // per record. No repair/truncate/delete/reopen/retry, including short writes.
  virtual WriteStatus write(const uint8_t *, size_t, size_t &) = 0;
  virtual WriteStatus flush() = 0;
};
class PersistentEvidence final : public r1::EvidenceSink {
public:
  PersistentEvidence(PersistencePort &, std::string batch, std::string target,
                     std::string owner, uint32_t max_records);
  r1::SinkReceipt preserve(const r1::Record &) override;
  bool failed() const { return failed_; }
  uint32_t writes() const { return writes_; }
  uint32_t flushes() const { return flushes_; }
private:
  PersistencePort &port_;
  const std::string batch_, target_, owner_;
  const uint32_t max_;
  uint32_t sequence_ = 0, writes_ = 0, flushes_ = 0;
  std::string previous_;
  bool failed_ = false;
};
struct Consumption {
  e4::Receipt receipt{};
  e4::Journal journal{};
  uint8_t marker = 0;
  BatchObjectPins pins;
  e4::ClockReading issued{}, now{};
  bool independently_pinned = false;
};
struct ProofPort {
  virtual ~ProofPort() = default;
  virtual bool read_once(Consumption &) = 0;
};
enum class State : uint32_t {
  preapproved, ready, accepted, consumed, intent, attempt, identity,
  acknowledged, resume_intent, resumed, exited, settled, released, unknown
};
// Separate versioned responsibility record, NOT an E4 fourth atomic file.
// Each 512-byte record has full target/batch/owner and a hash chain.
class CustodyJournal {
public:
  CustodyJournal(PersistencePort &, std::string batch, std::string target,
                 std::string owner);
  bool append(State, const r1::ProcessIdentity & = {});
  const std::string &last() const { return previous_; }
  bool failed() const { return failed_; }
  uint32_t count() const { return count_; }
private:
  PersistencePort &port_;
  const std::string batch_, target_, owner_;
  std::string previous_;
  uint32_t count_ = 0;
  bool failed_ = false;
};
// The injected OS owner lives in the Custodian process. Its HANDLEs NEVER
// cross the control wire, and it has no automatic destruction/termination.
struct OwnerPort : r1::CustodyPort {
  virtual bool sample_three(std::array<ResourceSample, 3> &) = 0;
};
class Custodian final : public r1::CustodyPort {
public:
  Custodian(r1::Frozen, Limits, OwnerPort &, ProofPort &, CustodyJournal &);
  r1::CustodyReceipt accept_intent(const r1::Frozen &) override;
  e4::WorkerStart create() override;
  r1::ProcessIdentity process_identity() override;
  r1::CustodyReceipt acknowledge_identity(const r1::ProcessIdentity &) override;
  bool token() override;
  bool image() override;
  bool dependencies() override;
  bool handles() override;
  bool resume(bool &) override;
  bool hello() override;
  bool approve(const e4::ApprovalPromptModel &, e4::ApprovalUiResponse &) override;
  e4::ClockReading read_clock() override;
  e5::Observation observe() override;
  bool next(e4::Frame &, bool &) override;
  bool send(const e4::Frame &) override;
  bool close_observed_exit() override;
  bool close_owned_io() override;
  void controller_lost() noexcept override;
  void custodian_lost() noexcept;
  State state() const { return state_; }
  bool retained() const { return attempted_ && state_ != State::released; }
  bool sample();
  const std::array<ResourceSample, 3> &peaks() const { return peaks_; }
private:
  bool persist(State);
  bool timely();
  bool proof();
  bool unknown();
  r1::CustodyReceipt receipt(bool);
  const r1::Frozen frozen_;
  const Limits limits_;
  OwnerPort &owner_;
  ProofPort &proof_;
  CustodyJournal &journal_;
  r1::ProcessIdentity identity_;
  State state_ = State::preapproved;
  e4::ClockValidator clock_;
  e4::ClockReading launch_{};
  bool accepted_ = false, attempted_ = false, resume_attempted_ = false,
       closed_ = false, io_closed_ = false, exit_ = false, stopped_ = false;
  uint32_t polls_ = 0, samples_ = 0, deps_ = 0, sends_ = 0, clocks_ = 0;
  std::array<ResourceSample, 3> peaks_{};
  std::array<uint32_t, 16> calls_{};
};

enum class Op : uint16_t {
  accept = 1, create, identity, acknowledge, token, image, dependencies,
  handles, resume, hello, observe, next, send, close_exit, close_io, stop
};
using Packet = std::array<uint8_t, 512>;
struct ControlPort {
  virtual ~ControlPort() = default;
  // Inherited pipe endpoints + retained peer PID/creation-time/image pin.
  // Neither an ordinary ACK nor same-SID membership proves persistence.
  virtual bool peer_checked() = 0;
  virtual bool exchange(const Packet &, Packet &) = 0;
};
class Endpoint {
public:
  Endpoint(r1::Frozen, std::string channel, Custodian &);
  bool dispatch(const Packet &, Packet &);
private:
  const r1::Frozen frozen_;
  const std::string channel_;
  Custodian &custodian_;
  uint32_t sequence_ = 0;
  bool failed_ = false;
};
// Controller owns UI/clock only. Every Worker operation traverses the separate
// bound control channel; there is no direct-create fallback.
class Proxy final : public r1::CustodyPort {
public:
  Proxy(r1::Frozen, std::string channel, ControlPort &, r1::CustodyPort &local);
  r1::CustodyReceipt accept_intent(const r1::Frozen &) override;
  e4::WorkerStart create() override;
  r1::ProcessIdentity process_identity() override;
  r1::CustodyReceipt acknowledge_identity(const r1::ProcessIdentity &) override;
  bool token() override; bool image() override; bool dependencies() override;
  bool handles() override; bool resume(bool &) override; bool hello() override;
  bool approve(const e4::ApprovalPromptModel &, e4::ApprovalUiResponse &) override;
  e4::ClockReading read_clock() override;
  e5::Observation observe() override;
  bool next(e4::Frame &, bool &) override;
  bool send(const e4::Frame &) override;
  bool close_observed_exit() override; bool close_owned_io() override;
  void controller_lost() noexcept override;
private:
  bool call(Op, const uint8_t * = nullptr, size_t = 0);
  r1::CustodyReceipt receipt(bool);
  const r1::Frozen frozen_;
  const std::string channel_;
  ControlPort &port_;
  r1::CustodyPort &local_;
  uint32_t sequence_ = 0;
  bool failed_ = false;
  Packet reply_{};
};
struct PollBudget {
  uint32_t limit = 0, polls = 0, reads = 0, writes = 0;
  bool failed = false;
  bool poll();
  bool read(size_t requested, size_t returned, bool eof);
  bool write(size_t requested, size_t returned, uint32_t maximum);
};
struct UiBudget {
  uint64_t origin = 0, duration = 0, last = 0;
  uint32_t limit = 0, events = 0;
  bool failed = false;
  bool event(uint64_t now);
};
// Concrete bootstrap has no backend, flag, environment override or Fake UI.
inline bool allow_live_execution() noexcept { return false; }
int custodian_process_entry(int argc, wchar_t **argv) noexcept;
} // namespace shiroha_l1_crypto::r2
#endif
