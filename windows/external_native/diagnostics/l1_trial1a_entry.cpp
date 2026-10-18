#include "diagnostics/l1_trial1a_entry.h"
namespace shiroha_l1_crypto::trial1a {
namespace {
s1::Request bound(const Target &t) {
  auto q = t.preparation;
  q.entry_binding = t.hash();
  return q;
}
const r1::Pin *image(const Target &t) {
  for (const auto &p : t.preparation.frozen.manifest.pins)
    if (p.id == t.image_id)
      return &p;
  return nullptr;
}
} // namespace
s1::Counts process_cost() {
  s1::Counts c{};
  // inspect_process_pin: token_validator + image_reader; measure_metadata.
  c[s1::os_calls] = 128;
  c[s1::files] = 2;
  c[s1::security_reads] = 1;
  c[s1::handles_acquired] = c[s1::handles_closed] = 2;
  return c;
}
s1::Counts ceiling(const s1::Request &q) {
  auto c = s1::ceiling(q.parents.size(), q.frozen.manifest.pins.size(),
                       q.evidence_parents.size());
  const auto overhead = process_cost();
  for (size_t i = 0; i < s1::counter_count; ++i)
    c[i] += 3 * overhead[i];
  return c;
}
bool Target::valid() const {
  if (!preparation.entry_binding.empty() || !preparation.valid() || !pid ||
      !creation || !safe_id(process_owner) || !safe_id(image_id))
    return false;
  const auto p = image(*this);
  if (!p || p->bytes_sha256 != preparation.frozen.manifest.build.controller ||
      p->owner != preparation.frozen.manifest.pin_owner)
    return false;
  // Reject incomplete budgets before even measurement/evidence creation.
  const auto base = s1::ceiling(preparation.parents.size(),
                                preparation.frozen.manifest.pins.size(),
                                preparation.evidence_parents.size());
  return preparation.budget == base && total_budget == ceiling(preparation);
}
std::string Target::hash() const {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_TRIAL1A_FIXED_ENTRY_V1");
  h.put_str(preparation.hash());
  h.put_u32_le(pid);
  h.put_u64_le(creation);
  h.put_str(process_owner);
  h.put_str(image_id);
  for (auto n : total_budget)
    h.put_u64_le(n);
  return h.finalize_hex();
}
Entry::Entry(Target t, s1::Operations &o, r1::EvidenceSink &s, ProcessPort &p)
    : target_(std::move(t)), operations_(o), process_(p),
      preparation_(bound(target_), *this, s) {}
bool Entry::reject(s1::Failure f, s1::State s) {
  rejected_ = true;
  failure_ = f;
  state_ = s;
  return false;
}
bool Entry::run_offline() try {
  if (attempted_)
    return false;
  attempted_ = true;
  if (operations_.origin() != r1::Origin::kFake ||
      process_.origin() != r1::Origin::kFake)
    return reject(s1::Failure::gate, s1::State::rejected);
  if (!target_.valid())
    return reject(s1::Failure::target, s1::State::rejected);
  preflight_ = process_cost(); // reserve all three failure envelopes first
  for (auto &n : preflight_)
    n *= 3;
  if (!inspect_process())
    return reject(s1::Failure::identity, s1::State::unknown);
  return preparation_.run_offline();
} catch (...) {
  return reject(s1::Failure::identity, s1::State::unknown);
}
bool Entry::inspect_process() {
  if (process_attempts_ == 3)
    return false;
  ++process_attempts_; // attempts, including a throwing/unknown measurement
  const auto m = process_.measure();
  const auto p = image(target_);
  return m.origin == r1::Origin::kFake && m.checked && m.pid == target_.pid &&
         m.creation == target_.creation && m.image == p->object &&
         m.security_sha256 == p->security_sha256;
}
bool Entry::run_windows() noexcept {
  if (attempted_)
    return false;
  attempted_ = true;
  return reject(s1::Failure::gate, s1::State::rejected);
}
s1::Runtime Entry::identity() {
  auto m = operations_.identity();
  if (m.facts.pid != target_.pid || m.facts.creation_time != target_.creation)
    return {};
  return m;
}
s1::Counts Entry::reserved() const {
  auto c = result().reserved;
  for (size_t i = 0; i < s1::counter_count; ++i)
    c[i] += preflight_[i];
  return c;
}
bool Entry::close_root_once(const std::string &owner) {
  return !rejected_ && preparation_.close_root_once(owner);
}
bool Entry::close_evidence_once(const std::string &owner) {
  return !rejected_ && preparation_.close_evidence_once(owner);
}
int process_entry(int, wchar_t **) noexcept { return 10; }
} // namespace shiroha_l1_crypto::trial1a
