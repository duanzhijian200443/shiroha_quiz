#include "protected_objects.h"
#include <cstring>
#include <limits>

namespace shiroha_native {
namespace {
size_t cap(uint32_t k) { return k == 1 ? 185u : k == 2 ? 1024u : k == 3 ? 36u : 0u; }
bool span(const void* p, uint64_t n) {
  return p && n && n <= SHIROHA_NATIVE_MAX_BYTES &&
      reinterpret_cast<uintptr_t>(p) <= (std::numeric_limits<uintptr_t>::max)() - n;
}
bool same(const ObjectInfo& a, const ObjectInfo& b) { return a.volume == b.volume && a.file == b.file; }
bool hex(const std::wstring& s, size_t n) {
  if (s.size() != n) return false;
  for (auto c : s) if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
  return true;
}
}

int32_t ProtectedObjects::discovery_directory(Lease& lease, Sid& sid) {
  auto status = check(lease, sid);
  if (status != SHIROHA_NATIVE_OK) return status;
  auto& pin = lease.discovery;
  if (!pin.handle) {
    status = ops_.child(lease.pins[2].handle, L"discovery", true, false, sid, pin.handle);
    if (status == SHIROHA_NATIVE_OK && (!pin.handle || pin.handle == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(pin.handle, pin.identity);
  }
  ObjectInfo current;
  if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(pin.handle, current);
  if (status == SHIROHA_NATIVE_OK && (!object_valid(current, sid, true, true, true) ||
      !same(current, pin.identity) || current.volume != lease.pins[2].identity.volume ||
      (lease.role == SHIROHA_NATIVE_APP && !same(current, lease.pins[7].identity)))) status = SHIROHA_NATIVE_UNAVAILABLE;
  if (status != SHIROHA_NATIVE_OK) lease.denied = true;
  return status;
}

int32_t ProtectedObjects::discovery_operation(uint64_t owner, uint32_t kind,
    const uint8_t* input, uint64_t length, uint8_t* output, uint64_t capacity,
    uint64_t* written, bool publish) {
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease || (publish && lease->role != SHIROHA_NATIVE_APP)) return SHIROHA_NATIVE_INVALID_INPUT;
  if (lease->ticket) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  HANDLE file = nullptr, temporary = nullptr, observed = nullptr;
  bool renaming = false;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  std::vector<uint8_t> bytes;
  ObjectInfo identity, temp_identity;
  auto close = [&](HANDLE& h) {
    if (h && h != INVALID_HANDLE_VALUE) {
      const auto ok = ops_.close(h); h = nullptr;
      if (!ok) { lease->denied = true; lease->quarantined = true; return false; }
    }
    return true;
  };
  try {
    Sid sid;
    status = discovery_directory(*lease, sid);
    if (status == SHIROHA_NATIVE_OK) status = ops_.discovery_open(lease->discovery.handle, kind, file);
    const bool missing = status == SHIROHA_NATIVE_MISSING;
    if (missing && file) status = SHIROHA_NATIVE_UNAVAILABLE;
    auto inspect = [&](HANDLE h, ObjectInfo& info) {
      if (!h || h == INVALID_HANDLE_VALUE) return static_cast<int32_t>(SHIROHA_NATIVE_UNAVAILABLE);
      auto s = ops_.inspect(h, info);
      if (s == SHIROHA_NATIVE_OK && (!object_valid(info, sid, false, true, true) ||
          info.volume != lease->discovery.identity.volume)) s = SHIROHA_NATIVE_UNAVAILABLE;
      return s;
    };
    if (status == SHIROHA_NATIVE_OK) status = inspect(file, identity);
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_read(file, cap(kind), bytes);
    if (status == SHIROHA_NATIVE_OK && (bytes.empty() || bytes.size() > cap(kind))) status = SHIROHA_NATIVE_DATA_CORRUPT;
    ObjectInfo after;
    if (status == SHIROHA_NATIVE_OK) status = inspect(file, after);
    if (status == SHIROHA_NATIVE_OK && !same(identity, after)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (publish && kind != 1 && status == SHIROHA_NATIVE_OK &&
        (bytes.size() != length || std::memcmp(bytes.data(), input, static_cast<size_t>(length)))) status = SHIROHA_NATIVE_DATA_CORRUPT;
    // Pin both the opened object and a fresh relative name before using bytes.
    if (status == SHIROHA_NATIVE_OK) status = ops_.discovery_open(lease->discovery.handle, kind, observed);
    if (status == SHIROHA_NATIVE_OK) status = inspect(observed, after);
    if (status == SHIROHA_NATIVE_OK && !same(identity, after)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (!close(observed)) status = SHIROHA_NATIVE_UNAVAILABLE;
    const bool create = publish && missing && status == SHIROHA_NATIVE_MISSING;
    const bool replace = publish && kind == 1 && status == SHIROHA_NATIVE_OK;
    if (create || replace) {
      status = discovery_directory(*lease, sid);
      size_t leftovers = 0;
      if (status == SHIROHA_NATIVE_OK) status = ops_.temporary_count(lease->discovery.handle, leftovers);
      if (status == SHIROHA_NATIVE_OK && leftovers >= 32) status = SHIROHA_NATIVE_RESOURCE_LIMIT;
      std::wstring runtime, random;
      if (status == SHIROHA_NATIVE_OK) status = ops_.random_name(runtime, random);
      if (status == SHIROHA_NATIVE_OK && (!hex(runtime, 16) || !hex(random, 8))) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) {
        if (lease->runtime_id.empty()) lease->runtime_id = runtime;
        status = ops_.temporary_create(lease->discovery.handle, L"~tmp-" + lease->runtime_id + L"-" + random, sid, temporary);
      }
      if (status == SHIROHA_NATIVE_OK) status = inspect(temporary, temp_identity);
      if (status == SHIROHA_NATIVE_OK) status = ops_.write_file(temporary, input, length);
      if (status == SHIROHA_NATIVE_OK) status = ops_.flush_file(temporary);
      if (status == SHIROHA_NATIVE_OK) status = inspect(temporary, after);
      if (status == SHIROHA_NATIVE_OK && !same(temp_identity, after)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) status = discovery_directory(*lease, sid);
      // Recheck the target name immediately before replacement (including Missing).
      if (status == SHIROHA_NATIVE_OK) {
        const auto s = ops_.discovery_open(lease->discovery.handle, kind, observed);
        if (create) status = s == SHIROHA_NATIVE_MISSING && !observed ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
        else {
          status = s;
          if (status == SHIROHA_NATIVE_OK) status = inspect(observed, after);
          if (status == SHIROHA_NATIVE_OK && !same(identity, after)) status = SHIROHA_NATIVE_UNAVAILABLE;
        }
      }
      if (!close(observed) || !close(file)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) {
        renaming = true;
        status = ops_.discovery_replace(temporary, lease->discovery.handle, kind, replace);
      }
      if (!close(temporary)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) status = ops_.discovery_open(lease->discovery.handle, kind, file);
      if (status == SHIROHA_NATIVE_OK) status = inspect(file, after);
      if (status == SHIROHA_NATIVE_OK && !same(temp_identity, after)) status = SHIROHA_NATIVE_UNAVAILABLE;
    }
    if (status == SHIROHA_NATIVE_OK) status = discovery_directory(*lease, sid);
  } catch (const std::bad_alloc&) { status = SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { status = SHIROHA_NATIVE_UNAVAILABLE; }
  if (!close(observed)) status = SHIROHA_NATIVE_UNAVAILABLE;
  if (!close(file)) status = SHIROHA_NATIVE_UNAVAILABLE;
  if (!close(temporary)) status = SHIROHA_NATIVE_UNAVAILABLE;
  // No deletion, retry, rollback or sweep, even when rename outcome is unknown.
  if (renaming && status != SHIROHA_NATIVE_OK) { lease->denied = true; return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
  if (!publish && status == SHIROHA_NATIVE_OK) { std::memcpy(output, bytes.data(), bytes.size()); *written = bytes.size(); }
  (void)capacity;
  return status;
}

int32_t ProtectedObjects::discovery_publish(uint32_t version, uint64_t owner, uint32_t kind,
    const uint8_t* input, uint64_t length) noexcept try {
  if (version != 3) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!cap(kind) || !span(input, length) || length > cap(kind) ||
      (kind != 2 && length != cap(kind))) return SHIROHA_NATIVE_INVALID_INPUT;
  return discovery_operation(owner, kind, input, length, nullptr, 0, nullptr, true);
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }

int32_t ProtectedObjects::discovery_read(uint32_t version, uint64_t owner, uint32_t kind,
    uint8_t* output, uint64_t capacity, uint64_t* written) noexcept try {
  if (!span(output, capacity) || !span(written, 8) || reinterpret_cast<uintptr_t>(written) % 8) return SHIROHA_NATIVE_INVALID_INPUT;
  const auto a = reinterpret_cast<uintptr_t>(output), b = reinterpret_cast<uintptr_t>(written);
  if (a < b + 8 && b < a + capacity) return SHIROHA_NATIVE_INVALID_INPUT;
  SecureZeroMemory(output, static_cast<SIZE_T>(capacity)); *written = 0;
  if (version != 3) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!cap(kind) || capacity != cap(kind)) return SHIROHA_NATIVE_INVALID_INPUT;
  return discovery_operation(owner, kind, nullptr, 0, output, capacity, written, false);
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}
