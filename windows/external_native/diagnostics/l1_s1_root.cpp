#include "diagnostics/l1_s1_root.h"

namespace shiroha_l1_crypto::s1 {
namespace {
void add(Counts &a, const Counts &b, uint64_t n = 1) {
  for (size_t i = 0; i < counter_count; ++i)
    a[i] += b[i] * n;
}
void object_hash(CanonicalHashBuilder &h, const ObjectIdentityPin &p) {
  h.put_u64_le(p.volume_serial);
  h.put_bytes(p.file_id.data(), 16);
}
bool chain_valid(const std::vector<r1::Pin> &pins) {
  if (pins.empty() || pins.size() > r2::kParents)
    return false;
  for (size_t i = 0; i < pins.size(); ++i) {
    const auto &p = pins[i];
    if (!p.object.valid() || !safe_id(p.id) || !safe_id(p.owner) ||
        !hex_digest(p.security_sha256, 64) ||
        p.parent != (i ? pins[i - 1].object : p.object))
      return false;
    for (size_t j = 0; j < i; ++j)
      if (pins[j].object == p.object || pins[j].id == p.id)
        return false;
    if (i && p.object.volume_serial != pins[0].object.volume_serial)
      return false;
  }
  return true;
}
bool directory_ok(const Observation &o) {
  return o.c_ntfs && o.directory && !o.reparse && !o.delete_pending &&
         o.exact_path && o.pin.object.valid();
}
// Closest existing R1 category; S1 adds no Failure enum value or record bytes.
// The exact S1 failure stays committed by the record's manifest digest.
r1::Failure code(Failure f) {
  switch (f) {
  case Failure::none:
    return r1::Failure::kNone;
  case Failure::gate:
    return r1::Failure::kGate;
  case Failure::target:
    return r1::Failure::kTarget;
  case Failure::identity:
    return r1::Failure::kMeasurement;
  case Failure::parent:
    return r1::Failure::kTarget; // approved target chain drifted
  case Failure::artifact:
    return r1::Failure::kMeasurement;
  case Failure::budget:
    return r1::Failure::kBudget;
  case Failure::creation:
    return r1::Failure::kTarget; // collision/denial of the target object
  case Failure::root:
    return r1::Failure::kMeasurement; // post-create identity/ACL revalidation
  case Failure::evidence:
    return r1::Failure::kEvidence;
  case Failure::handoff:
    return r1::Failure::kCustody;
  case Failure::close:
    return r1::Failure::kProcess; // owned OS handle settlement
  }
  return r1::Failure::kTarget;
}
} // namespace
Counts cost(Step s, size_t e) {
  Counts c{};
  switch (s) {
  case Step::identity:
    c[os_calls] = 128;
    c[handles_acquired] = c[handles_closed] = 2;
    break;
  case Step::parent:
    c[directories] = c[security_reads] = 1;
    c[os_calls] = 32;
    break;
  case Step::artifact:
    c[directories] = 16;
    c[files] = 3;
    c[security_reads] = 20;
    c[os_calls] = 1024;
    c[hash_reads] = 256;
    c[hash_bytes] = r2::kArtifactBytes;
    break;
  case Step::create:
    c[os_calls] = 32;
    c[root_creates] = c[security_sets] = c[handles_acquired] = 1;
    break;
  case Step::root:
    // inspect_e4_pin and measure_metadata each read the full metadata/security.
    c[directories] = 2;
    c[security_reads] = 2;
    c[os_calls] = 64;
    break;
  case Step::evidence_open:
    c[directories] = 2 * e + 2;
    c[files] = 1;
    c[security_reads] = 2 * e + 4;
    c[os_calls] = 2048;
    c[security_sets] = 1; // existing R2 output file's initial Owner/DACL
    c[evidence_creates] = c[handles_acquired] = 1;
    break;
  case Step::evidence:
    c[directories] = 2 * e + 3;
    c[files] = 3;
    c[security_reads] = 2 * e + 6;
    c[os_calls] = 2048;
    c[evidence_writes] = c[evidence_flushes] = 1;
    c[evidence_bytes] = r2::kRecordBytes;
    break;
  case Step::close:
    c[os_calls] = c[handles_closed] = 1;
    break;
  }
  return c;
}
Counts ceiling(size_t h, size_t a, size_t e) {
  Counts c{};
  if (!h || h > r2::kParents || !a || a > r2::kPins || !e || e > r2::kParents)
    return c;
  for (auto s : {Step::identity, Step::create, Step::evidence_open})
    add(c, cost(s, e));
  add(c, cost(Step::parent), 4 * h);
  add(c, cost(Step::artifact), a);
  add(c, cost(Step::root), 2);
  add(c, cost(Step::evidence, e), 2);
  add(c, cost(Step::close), 2);
  return c;
}
std::vector<std::string> parent_paths(const std::string &path) {
  std::vector<std::string> out;
  if (path.compare(0, 3, "C:\\"))
    return out;
  out.push_back("C:\\");
  for (size_t i = 3; i < path.size(); ++i)
    if (path[i] == '\\')
      out.push_back(path.substr(0, i));
  return out;
}
std::string pin_hash(const r1::Pin &p) {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_S1_PIN_V1");
  h.put_str(p.id);
  h.put_str(p.owner);
  h.put_str(p.security_sha256);
  h.put_str(p.bytes_sha256);
  object_hash(h, p.object);
  object_hash(h, p.parent);
  return h.finalize_hex();
}
std::string metadata_digest(const ObjectIdentityPin &o) {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_R2_METADATA_ONLY_V1");
  object_hash(h, o);
  return h.finalize_hex();
}
bool Request::valid() const {
  auto output_scope = frozen.target.scope;
  output_scope.directory = evidence_directory;
  if (!frozen.valid() || !limits.valid() ||
      frozen.manifest.r2_sha256 != limits.hash() || !chain_valid(parents) ||
      !chain_valid(evidence_parents) || !output_scope.valid() ||
      evidence_parents.size() < 2 ||
      evidence_parents.size() !=
          parent_paths(evidence_directory + "\\evidence-controller.r2")
              .size() ||
      parents.size() != parent_paths(frozen.target.scope.directory).size() ||
      frozen.manifest.pins.size() > r2::kPins || !safe_id(root_id) ||
      !hex_digest(root_security_sha256, 64) ||
      (!entry_binding.empty() && !hex_digest(entry_binding, 64)))
    return false;
  for (const auto &p : parents)
    if (p.owner != frozen.manifest.pin_owner ||
        p.bytes_sha256 != metadata_digest(p.object))
      return false;
  for (const auto &p : evidence_parents)
    if (p.owner != frozen.manifest.pin_owner ||
        p.bytes_sha256 != metadata_digest(p.object))
      return false;
  for (const auto *chain : {&parents, &evidence_parents})
    for (const auto &p : *chain)
      if (p.id == root_id)
        return false;
  const std::string images[] = {frozen.manifest.build.controller,
                                limits.custodian_sha256,
                                frozen.manifest.build.worker};
  for (const auto &image : images) {
    bool found = false;
    for (const auto &p : frozen.manifest.pins)
      if (p.bytes_sha256 == image)
        found = true;
    if (!found)
      return false;
  }
  for (const auto &p : frozen.manifest.pins)
    if (p.id == root_id)
      return false;
  const auto max = ceiling(parents.size(), frozen.manifest.pins.size(),
                           evidence_parents.size());
  for (size_t i = 0; i < counter_count; ++i)
    if (!budget[i] || budget[i] > max[i])
      return false;
  return true;
}
std::string Request::hash() const {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_S1_CREATE_UNDER_PARENT_V1");
  h.put_str(frozen.hash());
  h.put_str(root_id);
  h.put_str(root_security_sha256);
  h.put_str(evidence_directory);
  for (const auto *pins : {&parents, &evidence_parents}) {
    h.put_u32_le(uint32_t(pins->size()));
    for (const auto &p : *pins)
      h.put_str(pin_hash(p));
  }
  for (auto n : budget)
    h.put_u64_le(n);
  if (!entry_binding.empty()) {
    h.put_str("SHIROHA_L1_TRIAL1A_ENTRY_BINDING_V1");
    h.put_str(entry_binding);
  }
  return h.finalize_hex(); // no pre-create root identity exists in this request
}
Preparation::Preparation(Request r, Operations &o, r1::EvidenceSink &s)
    : request_(std::move(r)), ops_(o), sink_(s) {}
bool Preparation::fail(Failure f, bool unknown) {
  result_.stopped = true;
  if (result_.failure == Failure::none)
    result_.failure = f;
  result_.state =
      (unknown || result_.created || result_.state == State::unknown)
          ? State::unknown
          : State::rejected;
  return false;
}
bool Preparation::reserve(Step s) {
  const auto c = cost(s, request_.evidence_parents.size());
  for (size_t i = 0; i < counter_count; ++i)
    if (c[i] > request_.budget[i] - result_.reserved[i])
      return fail(Failure::budget);
  add(result_.reserved, c);
  return true;
}
bool Preparation::parents() {
  for (size_t i = 0; i < request_.parents.size(); ++i) {
    if (!reserve(Step::parent))
      return false;
    auto o = ops_.parent(i);
    if (!directory_ok(o) ||
        o.pin.bytes_sha256 != metadata_digest(o.pin.object) ||
        !(o.pin == request_.parents[i]))
      return fail(Failure::parent);
  }
  return true;
}
bool Preparation::root() {
  if (!reserve(Step::root))
    return false;
  auto o = ops_.root();
  if (!directory_ok(o) || o.pin.id != request_.root_id ||
      o.pin.owner != request_.frozen.manifest.pin_owner ||
      o.pin.parent != request_.parents.back().object ||
      o.pin.object.volume_serial != o.pin.parent.volume_serial ||
      o.pin.security_sha256 != request_.root_security_sha256 ||
      o.pin.bytes_sha256 != metadata_digest(o.pin.object))
    return fail(Failure::root);
  for (const auto &p : request_.parents)
    if (p.object == o.pin.object)
      return fail(Failure::root);
  for (const auto &p : request_.frozen.manifest.pins)
    if (p.object == o.pin.object)
      return fail(Failure::root);
  if (result_.root.object.valid() && !(result_.root == o.pin))
    return fail(Failure::root);
  result_.root = std::move(o.pin);
  return true;
}
bool Preparation::save(r1::Stage stage) {
  if (sink_failed_ || !result_.evidence_opened || !reserve(Step::evidence))
    return false;
  r1::Record r;
  r.stage = stage;
  r.sequence = ++result_.evidence_attempts;
  r.previous = result_.last.sequence ? result_.last.hash() : "";
  r.batch = request_.frozen.target.grant.batch_id;
  r.target = request_.frozen.hash();
  const auto &g = request_.frozen.target.grant;
  r.reviewer = g.reviewer_id;
  r.verifier = g.verifier_id;
  r.review_sha256 = g.review_sha256;
  r.verification_sha256 = g.verification_sha256;
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_S1_REDACTED_LEDGER_V1");
  h.put_str(request_.hash());
  h.put_str(pin_hash(result_.root));
  for (auto n : result_.reserved)
    h.put_u64_le(n);
  h.put_u32_le(result_.artifact_read_calls);
  h.put_u32_le(uint32_t(result_.failure));
  h.put_u32_le(uint32_t(result_.state));
  for (bool b : {result_.stopped, result_.create_attempted, result_.created,
                 result_.handoff_attempted, result_.handoff_acknowledged})
    h.put_bool(b);
  r.manifest =
      h.finalize_hex(); // binds allowlisted summary; no E4/Record format change
  r.recovery_required = result_.state == State::unknown;
  r.first_failure = code(result_.failure);
  result_.last = r;
  sink_failed_ = true; // thrown/partial/unknown acknowledgments never retry
  const auto ack = sink_.preserve(r);
  if (ack.origin != origin_ || ack.status != r1::IoStatus::kOk ||
      ack.sequence != r.sequence || ack.record_sha256 != r.hash())
    return fail(Failure::evidence, true);
  sink_failed_ = false;
  return true;
}
void Preparation::finish_failure() {
  // Only UNKNOWN requires external recovery; a rejected STOP is terminal.
  if (result_.evidence_opened && !sink_failed_ && result_.evidence_attempts < 2)
    save(result_.state == State::unknown ? r1::Stage::kRecoveryRequired
                                         : r1::Stage::kFinal);
}
bool Preparation::run_offline() { return run(r1::Origin::kFake); }
bool Preparation::run(r1::Origin origin) try {
  if (attempted_)
    return false;
  attempted_ = true;
  origin_ = origin;
  if (ops_.origin() != origin ||
      (origin != r1::Origin::kFake && origin != r1::Origin::kWindowsApi)) {
    result_.runtime_denied = true;
    return fail(Failure::gate);
  }
  if (!request_.valid())
    return fail(Failure::target);
  const auto work = [&]() {
    if (!reserve(Step::identity))
      return false;
    const auto m = ops_.identity();
    const auto &f = request_.frozen;
    if (m.facts.origin != origin_ ||
        m.device_sha256 != f.manifest.device_sha256 ||
        m.facts.os != f.manifest.os_sha256 ||
        m.facts.account != f.target.grant.account_identity_sha256 ||
        m.facts.sid != f.target.sid || !m.facts.primary_medium ||
        !m.facts.non_elevated || !m.facts.pid || !m.facts.creation_time)
      return fail(Failure::identity, true);
    if (!parents())
      return false;
    for (size_t i = 0; i < f.manifest.pins.size(); ++i) {
      if (!reserve(Step::artifact))
        return false;
      r1::Pin p;
      uint32_t reads = 0;
      const bool ok = ops_.artifact(i, p, reads);
      result_.artifact_read_calls += reads;
      if (!ok || !reads || reads > 256 || !(p == f.manifest.pins[i]))
        return fail(Failure::artifact);
    }
    if (!reserve(Step::evidence_open))
      return false;
    if (!ops_.open_evidence())
      return fail(Failure::evidence, true);
    result_.evidence_opened = true;
    if (!save(r1::Stage::kCreateIntent) || !parents() || !reserve(Step::create))
      return false;
    result_.create_attempted = true;
    const auto c = ops_.create_root();
    if (c != Creation::created)
      return fail(Failure::creation, c == Creation::unknown);
    result_.created = true;
    if (!root() || !parents() || !root() || !parents())
      return false;
    result_.handoff_attempted = true;
    const auto ack = ops_.handoff(result_.root, request_.hash());
    if (ack.status != r1::IoStatus::kOk || ack.owner != f.manifest.pin_owner ||
        ack.request != request_.hash() || ack.pin != pin_hash(result_.root))
      return fail(Failure::handoff, true);
    result_.handoff_acknowledged = true;
    result_.state = State::pinned;
    if (!save(r1::Stage::kFinal))
      return false;
    result_.evidence_preserved = true;
    return true;
  };
  if (work())
    return true;
  finish_failure();
  return false;
} catch (...) {
  fail(Failure::evidence, true);
  try {
    finish_failure();
  } catch (...) {
  }
  return false;
}
bool Preparation::close_root_once(const std::string &owner) {
  if (result_.state != State::pinned || !result_.evidence_preserved ||
      owner != request_.frozen.manifest.pin_owner ||
      result_.root_close_attempted)
    return false;
  if (!reserve(Step::close))
    return false;
  result_.root_close_attempted = true;
  try {
    result_.root_closed = ops_.close_root();
  } catch (...) {
  }
  return result_.root_closed || fail(Failure::close, true);
}
bool Preparation::close_evidence_once(const std::string &owner) {
  if (result_.state != State::pinned || !result_.evidence_preserved ||
      owner != request_.frozen.manifest.evidence_owner ||
      result_.evidence_close_attempted)
    return false;
  if (!reserve(Step::close))
    return false;
  result_.evidence_close_attempted = true;
  try {
    result_.evidence_closed = ops_.close_evidence();
  } catch (...) {
  }
  return result_.evidence_closed || fail(Failure::close, true);
}
int windows_process_entry(int, wchar_t **) noexcept {
  if (!windows_runtime_allowed())
    return 10;
  return 10; // no discovery or attach fallback, even in an altered build
}
} // namespace shiroha_l1_crypto::s1
