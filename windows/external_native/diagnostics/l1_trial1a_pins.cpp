#include "diagnostics/l1_trial1a_pins.h"
namespace shiroha_l1_crypto::trial1a {
namespace {
void add(s1::Counts &a, const s1::Counts &b) {
  for (size_t i = 0; i < s1::counter_count; ++i)
    a[i] += b[i];
}
std::string folded(std::string p) {
  for (auto &c : p)
    if (c >= 'a' && c <= 'z')
      c = char(c - 'a' + 'A');
  return p;
}
bool path_ok(const std::string &p) {
  if (p.size() < 3 || p.size() > 900 || p.compare(0, 3, "C:\\"))
    return false;
  if (p.size() == 3)
    return true;
  size_t start = 3;
  for (size_t i = 3; i <= p.size(); ++i) {
    if (i == p.size() || p[i] == '\\') {
      if (i == start || p[i - 1] == '.' || p[i - 1] == ' ')
        return false;
      start = i + 1;
    } else if (!((p[i] >= 'a' && p[i] <= 'z') || (p[i] >= 'A' && p[i] <= 'Z') ||
                 (p[i] >= '0' && p[i] <= '9') || p[i] == '-' || p[i] == '_' ||
                 p[i] == '.' || p[i] == ' '))
      return false;
  }
  return true;
}
Target bound(const PinPlan &p) {
  auto t = p.entry;
  t.acquisition_binding = p.hash();
  return t;
}
bool matches(const PinInput &p, const AcquiredPin &a) {
  auto expected = p.expected;
  if (!p.directory)
    expected.bytes_sha256.clear();
  return a.handle && a.handle != uintptr_t(-1) && a.c_ntfs &&
         a.directory == p.directory && !a.reparse && !a.delete_pending &&
         a.exact_path && a.owner_checked && a.measured == expected;
}
bool ack(const s1::Handoff &a, const PinPlan &p, const std::string &pins) {
  return a.status == r1::IoStatus::kOk &&
         a.owner == p.entry.preparation.frozen.manifest.pin_owner &&
         a.request == p.hash() && a.pin == pins;
}
} // namespace
s1::Counts acquisition_cost(bool directory) {
  s1::Counts c{};
  c[directory ? s1::directories : s1::files] = 1;
  c[s1::security_reads] = 1;
  c[s1::os_calls] =
      64; // open, actual ID, R2 metadata, allocations/failure paths
  c[s1::handles_acquired] = 1;
  return c;
}
s1::Counts binding_cost() {
  s1::Counts c{};
  c[s1::os_calls] = 1; // GetCurrentProcess pseudo-handle; no kernel acquisition
  return c;
}
s1::Counts acquisition_ceiling(const PinPlan &p) {
  auto c = p.entry.total_budget;
  if (p.objects.size() > kAcquisitionPins)
    return {};
  add(c, binding_cost());
  for (const auto &o : p.objects) {
    add(c, acquisition_cost(o.directory));
    add(c, s1::cost(s1::Step::close));
  }
  return c;
}
bool PinPlan::valid() const {
  const auto &q = entry.preparation;
  const auto &m = q.frozen.manifest;
  if (!entry.acquisition_binding.empty() || !entry.valid() || objects.empty() ||
      objects.size() > kAcquisitionPins ||
      budget != acquisition_ceiling(*this) ||
      parents.size() != q.parents.size() || artifacts.size() != m.pins.size() ||
      evidence_parents.size() != q.evidence_parents.size())
    return false;
  for (size_t i = 0; i < objects.size(); ++i) {
    const auto &o = objects[i];
    const auto &p = o.expected;
    const auto root = folded(q.frozen.target.scope.directory);
    const auto path = folded(o.path);
    if (path == root || path.compare(0, root.size() + 1, root + "\\") == 0 ||
        !path_ok(o.path) || !p.object.valid() || !safe_id(p.id) ||
        p.id == q.root_id || p.owner != m.pin_owner || o.owner_sid.empty() ||
        o.owner_sid.size() > 184 || !hex_digest(p.security_sha256, 64) ||
        !hex_digest(p.bytes_sha256, 64) ||
        (o.directory && p.bytes_sha256 != s1::metadata_digest(p.object)) ||
        (i ? o.parent >= i : o.parent != 0) || !objects[o.parent].directory ||
        p.parent != objects[o.parent].expected.object ||
        p.object.volume_serial != objects[0].expected.object.volume_serial)
      return false;
    if (!i) {
      if (o.path != "C:\\" || !o.directory)
        return false;
    } else {
      auto prefix = objects[o.parent].path;
      if (prefix.back() != '\\')
        prefix += '\\';
      if (o.path.compare(0, prefix.size(), prefix) ||
          o.path.size() <= prefix.size() ||
          o.path.find('\\', prefix.size()) != std::string::npos)
        return false;
    }
    size_t depth = 0, at = i;
    while (at) {
      ++depth;
      at = objects[at].parent;
    }
    if (depth + (o.directory ? 1u : 0u) > r2::kParents)
      return false;
    for (size_t j = 0; j < i; ++j)
      if (objects[j].expected.object == p.object ||
          objects[j].expected.id == p.id ||
          folded(objects[j].path) == folded(o.path))
        return false;
  }
  std::vector<bool> used(objects.size(), false);
  auto mark = [&](size_t n) {
    while (n) {
      used[n] = true;
      n = objects[n].parent;
    }
    used[0] = true;
  };
  auto chain = [&](const std::vector<size_t> &indices,
                   const std::vector<r1::Pin> &pins,
                   const std::vector<std::string> &paths) {
    if (indices.size() != paths.size())
      return false;
    for (size_t i = 0; i < indices.size(); ++i) {
      const auto n = indices[i];
      if (n >= objects.size() || !objects[n].directory ||
          !(objects[n].expected == pins[i]) || objects[n].path != paths[i] ||
          objects[n].parent != (i ? indices[i - 1] : n))
        return false;
      mark(n);
    }
    return true;
  };
  if (!chain(parents, q.parents,
             s1::parent_paths(q.frozen.target.scope.directory)) ||
      !chain(
          evidence_parents, q.evidence_parents,
          s1::parent_paths(q.evidence_directory + "\\evidence-controller.r2")))
    return false;
  bool image = false;
  for (size_t i = 0; i < artifacts.size(); ++i) {
    auto n = artifacts[i];
    if (n >= objects.size() || objects[n].directory ||
        !(objects[n].expected == m.pins[i]))
      return false;
    mark(n);
    image = image || m.pins[i].id == entry.image_id;
  }
  // Every file must be an approved artifact, every extra directory its
  // ancestor.
  return image &&
         std::all_of(used.begin(), used.end(), [](bool b) { return b; });
}
std::string PinPlan::hash() const {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_TRIAL1A_PIN_ACQUISITION_V1");
  h.put_str(entry.hash());
  h.put_u32_le(uint32_t(objects.size()));
  for (const auto &o : objects) {
    h.put_str(s1::pin_hash(o.expected));
    h.put_str(o.path);
    h.put_u32_le(uint32_t(o.owner_sid.size()));
    for (auto c : o.owner_sid)
      h.put_u16_le(uint16_t(c));
    h.put_u32_le(uint32_t(o.parent));
    h.put_bool(o.directory);
  }
  for (const auto *indices : {&parents, &artifacts, &evidence_parents}) {
    h.put_u32_le(uint32_t(indices->size()));
    for (auto n : *indices)
      h.put_u32_le(uint32_t(n));
  }
  for (auto n : budget)
    h.put_u64_le(n);
  return h.finalize_hex();
}
std::string borrow_hash(const PinPlan &p,
                        const std::vector<AcquiredPin> &pins) {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_TRIAL1A_RETAINED_BORROW_V1");
  h.put_str(p.hash());
  for (const auto &pin : pins) {
    h.put_str(s1::pin_hash(pin.measured));
    h.put_u64_le(uint64_t(pin.handle));
  }
  return h.finalize_hex();
}
Acquisition::Acquisition(PinPlan p, PinPort &a, s1::Operations &o,
                         r1::EvidenceSink &s, ProcessPort &process)
    : plan_(std::move(p)), port_(a), operations_(o), process_(process),
      entry_(bound(plan_), o, s, process) {}
bool Acquisition::fail(s1::State s) {
  failed_ = true;
  state_ = s;
  return false;
}
bool Acquisition::reserve(const s1::Counts &c) {
  const auto current = reserved();
  for (size_t i = 0; i < s1::counter_count; ++i)
    if (current[i] > plan_.budget[i] || c[i] > plan_.budget[i] - current[i])
      return fail();
  add(reserved_, c);
  return true;
}
s1::Counts Acquisition::reserved() const {
  auto c = reserved_;
  add(c, entry_.reserved());
  return c;
}
bool Acquisition::run_offline() { return run_controlled(r1::Origin::kFake); }
bool Acquisition::run_controlled(r1::Origin origin) try {
  if (attempted_)
    return false;
  attempted_ = true;
  if ((origin != r1::Origin::kFake && origin != r1::Origin::kWindowsApi) ||
      port_.origin() != origin || operations_.origin() != origin ||
      process_.origin() != origin || !plan_.valid())
    return fail(s1::State::rejected);
  acquired_.reserve(plan_.objects.size());
  for (size_t i = 0; i < plan_.objects.size(); ++i) {
    const auto &o = plan_.objects[i];
    if (!reserve(acquisition_cost(o.directory)))
      return false;
    ++acquisition_attempts_;
    auto pin = port_.acquire(i, o, i ? acquired_[o.parent].handle : 0);
    acquired_.push_back(pin); // even an ambiguous returned handle is retained
    if (!matches(o, pin))
      return fail();
    for (size_t j = 0; j < i; ++j)
      if (acquired_[j].handle == pin.handle)
        return fail();
  }
  borrowed_ = borrow_hash(plan_, acquired_);
  if (!reserve(binding_cost()))
    return false;
  if (!ack(port_.bind(plan_, acquired_), plan_, borrowed_))
    return fail();
  if (!entry_.run_controlled(origin))
    return fail(entry_.state());
  return true;
} catch (...) {
  return fail();
}
bool Acquisition::run_windows() noexcept {
  if (attempted_)
    return false;
  attempted_ = true;
  return fail(s1::State::rejected); // unconditional BEFORE acquire or attach
}
bool Acquisition::settle_once(const std::string &owner,
                              const std::string &evidence) try {
  if (!attempted_ || failed_ || settlement_attempted_ ||
      state() != s1::State::pinned ||
      owner != plan_.entry.preparation.frozen.manifest.pin_owner ||
      evidence != plan_.entry.preparation.frozen.manifest.evidence_owner)
    return false;
  settlement_attempted_ = true;
  if (!entry_.close_root_once(owner) || !entry_.close_evidence_once(evidence) ||
      !ack(port_.release_borrow(plan_.hash(), borrowed_), plan_, borrowed_))
    return fail();
  for (size_t i = acquired_.size(); i-- > 0;) {
    if (!reserve(s1::cost(s1::Step::close)) ||
        !port_.close(i, owner, acquired_[i].handle))
      return fail();
  }
  settled_ = true;
  return true;
} catch (...) {
  return fail();
}
} // namespace shiroha_l1_crypto::trial1a
