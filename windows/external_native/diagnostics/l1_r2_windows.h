#ifndef SHIROHA_L1_R2_WINDOWS_H_
#define SHIROHA_L1_R2_WINDOWS_H_
#include "diagnostics/l1_r2_adapters.h"
#include "diagnostics/l1_windows_operations.h"

namespace shiroha_l1_crypto::r2 {
// COMPILE ONLY, unlinked. No function in this file may be invoked by L0.
// All paths/handles are future approved inventory, never discovered defaults.
struct WindowsPinSpec {
  std::string id, owner;
  WindowsObjectPin object, parent;
  std::vector<WindowsObjectPin> chain;
  bool directory = false, artifact = false;
};
struct WindowsProcessPin {
  HANDLE process = nullptr; // borrowed from a named Owner, not an arbitrary PID
  DWORD pid = 0;
  uint64_t creation = 0;
  WindowsObjectPin image;
};
bool measure_runtime(HANDLE, RuntimeFacts &) noexcept;
bool measure_artifact(const WindowsObjectPin &, std::string &, uint32_t &) noexcept;
// S1 reuses the same R2 File ID/type/security measurement, without a Worker.
// One object observation, <=32 OS API calls, no HANDLE acquisition/closure.
bool measure_metadata(const WindowsObjectPin &, bool directory,
                      std::string &security_sha256, std::wstring &path) noexcept;
bool inspect_process_pin(const WindowsProcessPin &, const std::wstring &) noexcept;
bool bounded_dependencies(HANDLE, const std::vector<WindowsObjectPin> &,
                          const std::vector<std::string> &) noexcept;

class WindowsIdentity final : public r1::IdentityPort {
public:
  WindowsIdentity(std::vector<WindowsPinSpec>, std::array<WindowsProcessPin, 3>,
                  std::vector<HANDLE> inherited, r1::Frozen, Limits);
  r1::Measurement measure() override;
  // These are BORROWED pins: the named pin owner must acknowledge the close.
  bool close_borrowed_pins_once() override { return false; }
private:
  std::vector<WindowsPinSpec> pins_;
  std::array<WindowsProcessPin,3> processes_;
  std::vector<HANDLE> inherited_;
  const r1::Frozen frozen_;
  const Limits limits_;
  uint32_t measurements_ = 0;
};
enum class Output { custody, controller_evidence, custodian_evidence };
class WindowsPersistence final : public PersistencePort {
public:
  WindowsPersistence(WindowsObjectPin parent,std::vector<WindowsObjectPin> chain,Output);
  bool open_new() noexcept;
  r1::Origin origin() const noexcept override {return r1::Origin::kWindowsApi;}
  bool inspect_destination() override;
  WriteStatus write(const uint8_t *,size_t,size_t &) override;
  WriteStatus flush() override;
  bool close_once() noexcept;
  // No destructor close, reopen, deletion, truncation or automatic repair.
private:
  WindowsObjectPin parent_,file_;
  std::vector<WindowsObjectPin> chain_;
  Output output_;
  uint64_t length_=0;
  uint32_t writes_=0,flushes_=0;
  bool attempted_=false,closed_=false,failed_=false,pending_=false;
};
class WindowsProof final : public ProofPort {
public:
  WindowsProof(WindowsObjectPin parent,std::vector<WindowsObjectPin> chain,
               WindowsObjectPin receipt,WindowsObjectPin grant,WindowsObjectPin journal);
  bool read_once(Consumption &) override;
private:
  WindowsObjectPin parent_,receipt_,grant_,journal_;
  std::vector<WindowsObjectPin> chain_;
  bool attempted_=false;
};
// Fixed inherited pipe endpoints are an accidental-confusion boundary for a
// cooperative lab, not protection from malicious same-SID programs/admins.
class WindowsControl final : public ControlPort {
public:
  WindowsControl(HANDLE read,HANDLE write,WindowsProcessPin peer,std::wstring sid,
                 Limits,uint64_t launch_origin);
  bool peer_checked() override;
  bool exchange(const Packet &,Packet &) override;
  bool serve_once(Endpoint &);
private:
  bool take(Packet &);
  bool put(const Packet &);
  HANDLE read_,write_; // borrowed, owned exclusively by external pipe Owner
  WindowsProcessPin peer_;
  std::wstring sid_;
  const Limits limits_;
  uint64_t origin_;
  uint32_t polls_=0,reads_=0,writes_=0;
  bool checked_=false,failed_=false;
};
class WindowsWorkerLink final : public e4::WorkerLink {
public:
  WindowsWorkerLink(HANDLE read,HANDLE write,uint32_t polls,uint32_t poll_ms,uint64_t origin);
  bool send(const e4::Frame &) override;
  bool receive(e4::Frame &) override;
  bool checkpoint(L1CryptoLedger &) override;
  bool poll_control(e4::Frame &,bool &) override;
private:
  HANDLE read_,write_; // Worker owns and explicitly closes outside link
  PollBudget budget_;
  uint32_t poll_ms_,samples_=0;
  uint64_t origin_;
  e4::Frame partial_{};
  size_t used_=0;
};
bool bounded_approval(const e4::ApprovalPromptModel &,e4::ApprovalUiResponse &,
                      const Limits &) noexcept;

// Actual unique HANDLE owner candidate, located exclusively in Custodian.
// Controller/Custodian process pins and all artifact pins are borrowed.
class WindowsOwner final : public OwnerPort {
public:
  WindowsOwner(r1::Frozen,Limits,WindowsObjectPin directory,WindowsObjectPin image,
               std::vector<WindowsObjectPin> dependencies,std::vector<std::string> hashes,
               std::array<WindowsProcessPin,2> controller_custodian,uint64_t session);
  r1::CustodyReceipt accept_intent(const r1::Frozen &) override;
  e4::WorkerStart create() override;
  r1::ProcessIdentity process_identity() override;
  r1::CustodyReceipt acknowledge_identity(const r1::ProcessIdentity &) override;
  bool token() override; bool image() override; bool dependencies() override;
  bool handles() override; bool resume(bool &) override; bool hello() override;
  bool approve(const e4::ApprovalPromptModel &,e4::ApprovalUiResponse &) override;
  e4::ClockReading read_clock() override;
  e5::Observation observe() override;
  bool next(e4::Frame &,bool &) override; bool send(const e4::Frame &) override;
  bool close_observed_exit() override; bool close_owned_io() override;
  void controller_lost() noexcept override {stopped_=true;}
  std::array<ImageObservation, 3> measure_hosts() override;
  bool sample_three(std::array<ResourceSample,3> &) override;
private:
  bool create_suspended();
  // Metadata-only recheck after the once-per-Batch full image measurement.
  bool revalidate_hosts_no_read(const std::array<ImageObservation, 3> &) const;
  bool take(e4::Frame &,bool &);
  bool close_pipe(size_t);
  const r1::Frozen frozen_;
  const Limits limits_;
  WindowsObjectPin directory_,image_;
  std::vector<WindowsObjectPin> dependencies_;
  std::vector<std::string> hashes_;
  std::array<WindowsProcessPin,2> hosts_;
  uint64_t session_,origin_=0;
  SuspendedWorkerCustody custody_{};
  HANDLE pipes_[4]{};
  bool pipe_closed_[4]{};
  bool accepted_=false,attempted_=false,stopped_=false,exit_=false,io_closed_=false;
  bool ack_=false;
  bool hosts_measurement_attempted_=false;
  std::array<ImageObservation,3> host_images_{};
  uint32_t polls_=0,reads_=0,sends_=0;
  e4::Frame partial_{},hello_{};
  size_t used_=0;
  bool hello_pending_=false;
};
} // namespace shiroha_l1_crypto::r2
#endif
