#pragma once
#include "diagnostics/l1_r1_wiring.h"
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

using namespace shiroha_l1_crypto;
namespace x = shiroha_l1_crypto::e4;
namespace y = shiroha_l1_crypto::e5;
namespace r = shiroha_l1_crypto::r1;
namespace {
unsigned checks = 0;
void check(bool ok, const char *why) {
  ++checks;
  if (!ok) {
    std::cerr << "FAIL: " << why << '\n';
    std::exit(1);
  }
}
r::Frozen frozen() {
  r::Frozen f;
  auto &g = f.target.grant;
  auto &s = f.target.scope;
  for (auto p : {&g.batch_id, &g.device_id, &g.compiler_id, &g.os_id,
                 &g.stop_owner, &g.recovery_owner, &g.evidence_owner,
                 &g.reviewer_id, &g.verifier_id, &g.user_approval_id})
    *p = "SYNTHETIC-R1";
  for (auto p : {&g.account_identity_sha256, &g.exe_sha256,
                 &g.dependency_manifest_sha256, &g.toolchain_manifest_sha256,
                 &g.review_sha256, &g.verification_sha256})
    *p = std::string(64, '1');
  g.source_sha = g.base_sha = std::string(40, 'a');
  g.user_scope = "L1-ADMISSION";
  g.abi_limits = {0, 0, 0, 0, 0, 0, 0};
  g.non_elevated = g.reviewer_approved = g.verifier_approved =
      g.evidence_output_approved = true;
  g.working_set_bytes = 4096;
  g.commit_bytes = 8192;
  g.handles = 20;
  g.window_start_ms = 1700000000000ULL;
  g.window_end_ms = g.window_start_ms + 120000;
  s.directory = "C:\\SYNTHETIC\\R1";
  s.cleanup_owner = "SYNTHETIC-R1";
  s.controller_exe_sha256 = s.recovery_record_sha256 = std::string(64, '2');
  s.controller_working = 2048;
  s.controller_commit = 4096;
  s.controller_handles = 10;
  s.recovery_approved = true;
  f.target.sid = L"FAKE-SID";
  auto &m = f.manifest;
  m.device_sha256 = std::string(64, '3');
  m.os_sha256 = std::string(64, '4');
  m.pin_owner = "FAKE-PIN-OWNER";
  m.custody_owner = "FAKE-CREATOR";
  m.evidence_owner = g.evidence_owner;
  m.max_pumps = 128;
  m.build = {r::Origin::kFake,
             g.source_sha,
             g.base_sha,
             g.toolchain_manifest_sha256,
             s.controller_exe_sha256,
             g.exe_sha256,
             g.dependency_manifest_sha256};
  for (uint8_t i = 1; i <= 3; ++i) {
    r::Pin p;
    p.id = "PIN-" + std::to_string(i);
    p.owner = m.pin_owner;
    p.security_sha256 = p.bytes_sha256 = std::string(64, '5');
    p.object.volume_serial = p.parent.volume_serial = 9;
    p.object.file_id[0] = i;
    p.parent.file_id[0] = 7;
    m.pins.push_back(p);
  }
  s.wiring_manifest_sha256 = m.hash();
  g.evidence_scope_id = s.hash();
  check(f.valid(), "valid separately supplied fixed target");
  return f;
}
struct Io final : x::GrantIo {
  unsigned issues = 0, requests = 0, burns = 0, starts = 0;
  bool issued = false, requested = false;
  x::Journal journal{};
  x::Receipt saved_receipt{};
  bool principal(const std::wstring &s) override { return s == L"FAKE-SID"; }
  x::IoResult issue_new(const x::Receipt &receipt, BatchObjectPins &p) override {
    ++issues;
    saved_receipt = receipt;
    if (issued)
      return x::IoResult::denied;
    issued = true;
    uint8_t i = 1;
    for (auto q : {&p.dir_pin, &p.receipt_pin, &p.grant_pin}) {
      q->volume_serial = 9;
      q->file_id[0] = i++;
    }
    return x::IoResult::ok;
  }
  bool inspect(const BatchObjectPins &p) override { return p.valid(); }
  x::IoResult request_new(const x::Journal &j) override {
    ++requests;
    if (requested)
      return x::IoResult::denied;
    requested = true;
    journal = j;
    return x::IoResult::ok;
  }
  x::IoResult burn_issued() override {
    ++burns;
    return x::IoResult::ok;
  }
  x::IoResult update_request(const x::Journal &j) override {
    journal = j;
    if (j[6] == 3)
      ++starts;
    return x::IoResult::ok;
  }
};
struct Id final : r::IdentityPort {
  const r::Frozen &f;
  unsigned calls = 0, closes = 0, drift_at = 0, drift_kind = 0;
  explicit Id(const r::Frozen &v) : f(v) {}
  r::Measurement measure() override {
    ++calls;
    r::Measurement m;
    m.origin = r::Origin::kFake;
    m.device_sha256 = f.manifest.device_sha256;
    m.os_sha256 = f.manifest.os_sha256;
    m.account_sha256 = f.target.grant.account_identity_sha256;
    m.token_sid = f.target.sid;
    m.primary_medium = m.non_elevated = m.minimal_privileges = true;
    m.build = f.manifest.build;
    m.pins = f.manifest.pins;
    if (calls == drift_at) {
      switch (drift_kind) {
      case 0:
        m.device_sha256 = std::string(64, '8');
        break;
      case 1:
        m.os_sha256 = std::string(64, '8');
        break;
      case 2:
        m.token_sid = L"WRONG-SID";
        break;
      case 3:
        m.account_sha256 = std::string(64, '8');
        break;
      case 4:
        m.primary_medium = false;
        break;
      case 5:
        m.build.dependencies = std::string(64, '8');
        break;
      case 6:
        m.pins[0].object.file_id[0] = 99;
        break;
      case 7:
        m.pins[0].parent.file_id[0] = 99;
        break;
      case 8:
        m.pins[0].security_sha256 = std::string(64, '8');
        break;
      case 9:
        m.pins[0].owner = "WRONG-OWNER";
        break;
      case 10:
        m.build.toolchain = std::string(64, '8');
        break;
      case 11:
        m.build.controller = std::string(64, '8');
        break;
      case 12:
        m.build.worker = std::string(64, '8');
        break;
      case 13:
        m.build.source = std::string(40, 'b');
        break;
      default:
        m.origin = r::Origin::kWindowsApi;
        break;
      }
    }
    return m;
  }
  bool close_borrowed_pins_once() override { return ++closes == 1; }
};
struct Sink final : r::EvidenceSink {
  std::vector<r::Record> records;
  r::Stage fail_stage = r::Stage::kControllerStarted;
  bool fail = false, unknown = false, bad_digest = false,
       write_then_lose_ack = false;
  unsigned calls = 0;
  r::SinkReceipt preserve(const r::Record &v) override {
    ++calls;
    check(v.sequence == records.size() + 1, "external sink monotonic sequence");
    check(v.previous ==
              (records.empty() ? std::string{} : records.back().hash()),
          "external sink integrity chain");
    if (fail && v.stage == fail_stage) {
      if (write_then_lose_ack)
        records.push_back(v);
      return {r::Origin::kFake,
              unknown ? r::IoStatus::kUnknown : r::IoStatus::kDenied,
              0,
              {}};
    }
    records.push_back(v);
    return {r::Origin::kFake, r::IoStatus::kOk, v.sequence,
            bad_digest ? std::string(64, '0') : v.hash()};
  }
};
struct Wire final : x::WorkerLink {
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<x::Frame> to_controller, to_worker;
  bool cancelled = false, done = false, acked = false;
  int exit_code = 10;
  unsigned checkpoints = 0;
  bool send(const x::Frame &f) override {
    std::lock_guard<std::mutex> lock(mutex);
    to_controller.push_back(f);
    changed.notify_all();
    return !cancelled;
  }
  bool receive(x::Frame &f) override {
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [&] { return cancelled || !to_worker.empty(); });
    if (cancelled)
      return false;
    f = to_worker.front();
    to_worker.pop_front();
    return true;
  }
  bool checkpoint(L1CryptoLedger &l) override {
    ++checkpoints;
    return l.resources(2048, 4096, 4);
  }
  bool poll_control(x::Frame &f, bool &available) override {
    std::lock_guard<std::mutex> lock(mutex);
    available = !to_worker.empty();
    if (available) {
      f = to_worker.front();
      to_worker.pop_front();
    }
    return !cancelled;
  }
  void stop_fake_transport() {
    std::lock_guard<std::mutex> lock(mutex);
    cancelled = true;
    changed.notify_all();
  }
};
bool clock_worker(uint64_t &n) noexcept {
  n = 500;
  return true;
}
struct WorkerBoot final : r::EntryPort {
  r::Frozen f;
  Wire &wire;
  WorkerBoot(r::Frozen v, Wire &w) : f(std::move(v)), wire(w) {}
  r::Origin origin() const noexcept override { return r::Origin::kFake; }
  r::Composition *attach_controller() noexcept override { return nullptr; }
  bool attach_worker(r::WorkerInvocation &w) override {
    w.frozen = f;
    w.link = &wire;
    w.pid = 321;
    w.clock = clock_worker;
    w.inherited_pipe_tokens = {101, 102};
    return true;
  }
};
// All state below belongs to a separate Fake creator object whose lifetime
// exceeds the Controller. It is NOT a real process, disk journal or OS proof.
struct Creator final : r::CustodyPort {
  const r::Frozen &f;
  Io &io;
  Wire wire;
  std::thread worker;
  unsigned accepts = 0, creates = 0, resumes = 0, close_calls = 0,
           io_closes = 0;
  bool accepted = false, attempted = false, created = false, ack = false,
       lost = false;
  bool owner_handles = false, cancel = false, accept_denied = false,
       ack_lost = false;
  bool wrong_process = false, no_exit = false, wrong_dependency = false;
  bool close_unknown = false;
  bool wrong_ack_identity = false, deadline_during_ack = false;
  int crash = 0;
  uint64_t mono = 500;
  Creator(const r::Frozen &v, Io &i) : f(v), io(i) {}
  ~Creator() {
    wire.stop_fake_transport();
    if (worker.joinable())
      worker.join();
  }
  r::CustodyReceipt receipt(bool handles) {
    return {r::Origin::kFake,
            r::IoStatus::kOk,
            f.manifest.custody_owner,
            f.hash(),
            std::string(64, '6'),
            true,
            handles,
            {}};
  }
  r::CustodyReceipt accept_intent(const r::Frozen &v) override {
    ++accepts;
    if (accepted || lost || accept_denied || v.hash() != f.hash())
      return {};
    accepted = true;
    if (crash == 1)
      throw std::runtime_error("fake external acceptance window");
    return receipt(false);
  }
  x::WorkerStart create() override {
    check(accepted && io.burns == 1 && io.journal[6] == 3,
          "external acceptance and durable consume precede create");
    if (attempted || lost)
      return {};
    attempted = true;
    ++creates;
    if (crash == 2)
      throw std::runtime_error("fake before create window");
    created = owner_handles = true;
    if (crash == 3)
      throw std::runtime_error("fake after create window");
    x::WorkerStart s;
    s.created = true;
    s.pid = 321;
    return s;
  }
  r::ProcessIdentity process_identity() override {
    if (crash == 4)
      throw std::runtime_error("fake identity before handoff window");
    return {321,
            12345,
            f.target.grant.exe_sha256,
            f.target.grant.account_identity_sha256,
            wrong_process ? std::string(64, '0') : f.hash(),
            f.manifest.custody_owner,
            true,
            true};
  }
  r::CustodyReceipt acknowledge_identity(const r::ProcessIdentity &p) override {
    ack = true;
    if (crash == 5)
      throw std::runtime_error("fake handoff ack window");
    if (ack_lost)
      return {};
    auto r = receipt(owner_handles);
    r.process_identity_sha256 =
        wrong_ack_identity ? std::string(64, '0') : p.hash();
    if (deadline_during_ack)
      mono = 30500;
    return r;
  }
  void controller_lost() noexcept override { lost = true; }
  bool token() override { return true; }
  bool image() override { return true; }
  bool dependencies() override { return !wrong_dependency; }
  bool handles() override { return owner_handles; }
  bool resume(bool &known) override {
    check(ack && !resumes && !lost, "custodian ack before sole Resume");
    ++resumes;
    known = true;
    worker = std::thread([this] {
      WorkerBoot boot(f, wire);
      wchar_t name[] = L"l1-worker", a[] = L"101", b[] = L"102";
      wchar_t *argv[] = {name, a, b};
      int code = r::worker_process_entry(3, argv, boot);
      std::lock_guard<std::mutex> lock(wire.mutex);
      wire.exit_code = code;
      wire.done = true;
      wire.changed.notify_all();
    });
    if (crash == 6)
      throw std::runtime_error("fake after Resume window");
    return true;
  }
  bool hello() override {
    std::unique_lock<std::mutex> lock(wire.mutex);
    wire.changed.wait(lock,
                      [&] { return wire.done || !wire.to_controller.empty(); });
    return !wire.to_controller.empty();
  }
  bool approve(const x::ApprovalPromptModel &p,
               x::ApprovalUiResponse &r) override {
    r = {true, cancel, false, true, p.suffix, p.target_hash};
    return !cancel;
  }
  x::ClockReading read_clock() override {
    return {f.target.grant.window_start_ms + mono - 500, mono, 42, true};
  }
  y::Observation observe() override {
    std::unique_lock<std::mutex> lock(wire.mutex);
    if (wire.acked)
      wire.changed.wait(lock, [&] { return wire.done; });
    const bool exited = wire.done && !no_exit;
    return {{mono, 2048, 4096, exited ? 0u : 4u, 0},
            {mono, 1024, 2048, 4, 0},
            true,
            exited,
            wire.exit_code == 0};
  }
  bool next(x::Frame &v, bool &available) override {
    std::unique_lock<std::mutex> lock(wire.mutex);
    wire.changed.wait(lock,
                      [&] { return wire.done || !wire.to_controller.empty(); });
    available = !wire.to_controller.empty();
    if (available) {
      v = wire.to_controller.front();
      wire.to_controller.pop_front();
    }
    return true;
  }
  bool send(const x::Frame &v) override {
    std::lock_guard<std::mutex> lock(wire.mutex);
    if (x::get(v.data() + 6, 2) == unsigned(x::Message::ack))
      wire.acked = true;
    wire.to_worker.push_back(v);
    wire.changed.notify_all();
    return true;
  }
  bool close_observed_exit() override {
    ++close_calls;
    if (no_exit || !wire.done || !owner_handles || close_unknown)
      return false;
    owner_handles = false;
    return true;
  }
  bool close_owned_io() override {
    ++io_closes;
    wire.stop_fake_transport();
    return true;
  }
};
struct Fixture {
  r::Frozen f = frozen();
  Io io;
  Id id{f};
  Creator owner{f, io};
  Sink sink;
  r::Composition c{f, io, id, owner, sink};
  void finish() {
    for (unsigned i = 0; i < 140 && c.pump(); ++i) {
    }
  }
};
struct ControllerBoot final : r::EntryPort {
  r::Composition &c;
  explicit ControllerBoot(r::Composition &v) : c(v) {}
  r::Origin origin() const noexcept override { return r::Origin::kFake; }
  r::Composition *attach_controller() noexcept override { return &c; }
  bool attach_worker(r::WorkerInvocation &) override { return false; }
};
} // namespace
