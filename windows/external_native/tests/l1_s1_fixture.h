#ifndef SHIROHA_L1_S1_FIXTURE_H_
#define SHIROHA_L1_S1_FIXTURE_H_
#include "diagnostics/l1_s1_root.h"
#include "diagnostics/l1_temporary_handle.h"
#include "tests/l1_r1_fixture.h"
#include <type_traits>
namespace s = shiroha_l1_crypto::s1;
namespace z = shiroha_l1_crypto::r2;
namespace {
s::Request request() {
  s::Request q;
  q.frozen = frozen();
  q.limits.custodian_sha256 = std::string(64, '7');
  q.limits.channel_sha256 = std::string(64, '8');
  q.limits.process = {z::ResourceLimit{2048, 4096, 10},
                      z::ResourceLimit{3072, 6144, 16},
                      z::ResourceLimit{4096, 8192, 20}};
  q.limits.polls = 128;
  q.limits.poll_ms = 10;
  q.limits.ui_events = 64;
  q.limits.approval_ms = 30000;
  q.limits.handoff_ms = 15000;
  auto &f = q.frozen;
  f.manifest.pins[0].bytes_sha256 = f.manifest.build.controller;
  f.manifest.pins[1].bytes_sha256 = q.limits.custodian_sha256;
  f.manifest.pins[2].bytes_sha256 = f.manifest.build.worker;
  f.manifest.r2_sha256 = q.limits.hash();
  f.target.scope.wiring_manifest_sha256 = f.manifest.hash();
  f.target.grant.evidence_scope_id = f.target.scope.hash();
  for (uint8_t i = 0; i < 3; ++i) {
    r::Pin p;
    p.id = "ANCESTOR-" + std::to_string(i);
    p.owner = f.manifest.pin_owner;
    p.object.volume_serial = 9;
    p.object.file_id[0] = uint8_t(40 + i);
    p.parent = i ? q.evidence_parents.back().object : p.object;
    p.security_sha256 = std::string(64, '9');
    p.bytes_sha256 = s::metadata_digest(p.object);
    q.evidence_parents.push_back(p);
    if (i < 2)
      q.parents.push_back(p);
  }
  q.root_id = "NEW-ROOT";
  q.root_security_sha256 = std::string(64, '6');
  q.evidence_directory = "C:\\SYNTHETIC\\EVIDENCE";
  q.budget = s::ceiling(q.parents.size(), f.manifest.pins.size(),
                        q.evidence_parents.size());
  check(q.valid(), "separately supplied synthetic preparation request");
  return q;
}
struct Disk final : z::PersistencePort {
  uint32_t writes = 0, flushes = 0, inspects = 0, fail_write = 0,
           fail_flush = 0;
  bool short_write = false;
  std::vector<std::vector<uint8_t>> bytes;
  r::Origin origin() const noexcept override { return r::Origin::kFake; }
  bool inspect_destination() override {
    ++inspects;
    return true;
  }
  z::WriteStatus write(const uint8_t *p, size_t n, size_t &done) override {
    ++writes;
    if (writes == fail_write)
      return z::WriteStatus::unknown;
    done = short_write ? n - 1 : n;
    bytes.emplace_back(p, p + n);
    return z::WriteStatus::ok;
  }
  z::WriteStatus flush() override {
    return ++flushes == fail_flush ? z::WriteStatus::unknown
                                   : z::WriteStatus::ok;
  }
};
struct S1Sink final : r::EvidenceSink {
  z::PersistentEvidence persisted;
  uint32_t calls = 0, lost_ack = 0;
  S1Sink(Disk &d, const s::Request &q)
      : persisted(d, q.frozen.target.grant.batch_id, q.frozen.hash(),
                  q.frozen.manifest.evidence_owner, 2) {}
  r::SinkReceipt preserve(const r::Record &r) override {
    ++calls;
    auto ack = persisted.preserve(r);
    if (calls == lost_ack)
      ack.record_sha256 = std::string(64, '0');
    return ack;
  }
};
struct Ops final : s::Operations {
  s::Request q;
  r::Origin source = r::Origin::kFake;
  unsigned identities = 0, parent_calls = 0, artifacts = 0, creates = 0,
           roots = 0, opens = 0, handoffs = 0, root_closes = 0,
           evidence_closes = 0;
  unsigned drift_call = 0, drift_kind = 0, root_fail = 0;
  uint32_t forced_reads = 256;
  bool bad_identity = false, bad_artifact = false, bad_handoff = false,
       throw_handoff = false, close_failure = false, open_failure = false,
       root_identity_drift = false, wrong_root_digest = false;
  s::Creation creation = s::Creation::created;
  r::Pin actual;
  explicit Ops(s::Request r) : q(std::move(r)) {
    actual.id = q.root_id;
    actual.owner = q.frozen.manifest.pin_owner;
    actual.object.volume_serial = 9;
    actual.object.file_id[0] = 80;
    actual.parent = q.parents.back().object;
    actual.security_sha256 = q.root_security_sha256;
    actual.bytes_sha256 = s::metadata_digest(actual.object);
  }
  r::Origin origin() const noexcept override { return source; }
  s::Runtime identity() override {
    ++identities;
    s::Runtime m;
    auto &f = m.facts;
    f.origin = source;
    f.sid = q.frozen.target.sid;
    f.os = q.frozen.manifest.os_sha256;
    f.account = q.frozen.target.grant.account_identity_sha256;
    f.primary_medium = f.non_elevated = !bad_identity;
    f.pid = 5;
    f.creation_time = 55;
    m.device_sha256 = q.frozen.manifest.device_sha256;
    return m;
  }
  s::Observation parent(size_t i) override {
    ++parent_calls;
    s::Observation o{q.parents[i], true, true, false, false, true};
    if (parent_calls == drift_call) {
      switch (drift_kind) {
      case 0:
        ++o.pin.object.volume_serial;
        o.pin.bytes_sha256 = s::metadata_digest(o.pin.object);
        break;
      case 1:
        ++o.pin.object.file_id[0];
        o.pin.bytes_sha256 = s::metadata_digest(o.pin.object);
        break;
      case 2:
        o.pin.owner = "OTHER-OWNER";
        break;
      case 3:
        o.pin.security_sha256 = std::string(64, '0');
        break;
      case 4:
        o.reparse = true;
        break;
      case 5:
        o.directory = false;
        break;
      case 6:
        o.c_ntfs = false;
        break;
      case 7:
        o.exact_path = false;
        break;
      case 8:
        o.delete_pending = true;
        break;
      default:
        return {};
      }
    }
    return o;
  }
  bool artifact(size_t i, r::Pin &p, uint32_t &reads) override {
    ++artifacts;
    p = q.frozen.manifest.pins[i];
    reads = forced_reads;
    if (bad_artifact)
      p.bytes_sha256 = std::string(64, '0');
    return true;
  }
  s::Creation create_root() override {
    ++creates;
    return creation;
  }
  s::Observation root() override {
    ++roots;
    if (roots == root_fail)
      return {};
    if (roots == 2 && root_identity_drift) {
      ++actual.object.file_id[0];
      actual.bytes_sha256 = s::metadata_digest(actual.object);
    }
    r::Pin p = actual;
    if (wrong_root_digest)
      p.bytes_sha256 = std::string(64, '0');
    return {p, true, true, false, false, true};
  }
  bool open_evidence() override {
    ++opens;
    return !open_failure;
  }
  s::Handoff handoff(const r::Pin &p, const std::string &h) override {
    ++handoffs;
    if (throw_handoff)
      throw std::runtime_error("synthetic");
    return {bad_handoff ? r::IoStatus::kUnknown : r::IoStatus::kOk, p.owner, h,
            s::pin_hash(p)};
  }
  bool close_root() override {
    ++root_closes;
    return !close_failure;
  }
  bool close_evidence() override {
    ++evidence_closes;
    return !close_failure;
  }
};
struct S1Fixture {
  s::Request q = request();
  Ops ops{q};
  Disk disk;
  S1Sink S1Sink{disk, q};
  s::Preparation preparation{q, ops, S1Sink};
};
} // namespace
#endif
