#include "protected_objects.h"
#include <cstring>
#include <limits>

namespace shiroha_native {
namespace {
bool span(const void* p, uint64_t n) noexcept {
  return p && n > 0 && n <= SHIROHA_NATIVE_MAX_BYTES &&
      reinterpret_cast<uintptr_t>(p) <= (std::numeric_limits<uintptr_t>::max)() - n;
}
bool count(uint64_t* p) noexcept { return span(p, 8) && reinterpret_cast<uintptr_t>(p) % 8 == 0; }
bool overlap(const void* a, uint64_t n, const void* b, uint64_t m) noexcept {
  const auto x = reinterpret_cast<uintptr_t>(a), y = reinterpret_cast<uintptr_t>(b);
  return x < y + m && y < x + n;
}
bool hex(const std::wstring& s, size_t n) noexcept {
  if (s.size() != n) return false;
  for (const auto c : s) if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
  return true;
}
}  // namespace

ProtectedObjects::Lease* ProtectedObjects::find(uint64_t token) noexcept {
  for (auto& lease : owners_) if (lease && lease->token == token) return lease.get();
  return nullptr;
}
int32_t ProtectedObjects::check(Lease& lease, Sid& sid) {
  if (lease.denied || lease.quarantined || lease.role != SHIROHA_NATIVE_APP)
    return SHIROHA_NATIVE_UNAVAILABLE;
  lease.denied = true;
  auto status = ops_.user_sid(sid);
  if (status == SHIROHA_NATIVE_OK) status = inspect_pins(lease, sid);
  lease.denied = status != SHIROHA_NATIVE_OK;
  return status;
}
bool ProtectedObjects::finish(Lease& lease) noexcept {
  bool ok = true;
  for (auto* handle : {&lease.temporary, &lease.target}) {
    if (*handle && *handle != INVALID_HANDLE_VALUE && !ops_.close(*handle)) ok = false;
    // Unknown close must never be retried on a potentially reused OS handle.
    *handle = nullptr;
  }
  lease.ticket = 0;
  if (!ok) { lease.denied = true; lease.quarantined = true; }
  return ok;
}
int32_t ProtectedObjects::target_current(Lease& lease, const Sid& sid) {
  // App acquisition fixes state at pin 6, after the OS-exclusive lock at 3.
  if (lease.pins.size() != 9) return SHIROHA_NATIVE_UNAVAILABLE;
  HANDLE observed = nullptr;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  try {
    status = ops_.association_open(lease.pins[6].handle, sid, observed);
    if (status == SHIROHA_NATIVE_MISSING) {
      status = lease.missing ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
    } else if (status == SHIROHA_NATIVE_OK && observed && observed != INVALID_HANDLE_VALUE) {
      ObjectInfo info;
      status = ops_.inspect(observed, info);
      if (status == SHIROHA_NATIVE_OK &&
          (lease.missing || !object_valid(info, sid, false, true, true) ||
           info.volume != lease.target_identity.volume || info.file != lease.target_identity.file))
        status = SHIROHA_NATIVE_UNAVAILABLE;
    } else if (status == SHIROHA_NATIVE_OK) status = SHIROHA_NATIVE_UNAVAILABLE;
  } catch (...) {
    if (observed && observed != INVALID_HANDLE_VALUE && !ops_.close(observed)) {
      lease.denied = true; lease.quarantined = true;
    }
    throw;
  }
  if (observed && observed != INVALID_HANDLE_VALUE && !ops_.close(observed)) {
    lease.denied = true; lease.quarantined = true;
    return SHIROHA_NATIVE_UNAVAILABLE;
  }
  return status;
}

int32_t ProtectedObjects::association_begin(uint32_t version, uint64_t owner,
    uint8_t* output, uint64_t capacity, uint64_t* written, uint64_t* ticket) noexcept try {
  if (!span(output, capacity) || !count(written) || !count(ticket) ||
      overlap(output, capacity, written, 8) || overlap(output, capacity, ticket, 8) ||
      overlap(written, 8, ticket, 8)) return SHIROHA_NATIVE_INVALID_INPUT;
  SecureZeroMemory(output, static_cast<SIZE_T>(capacity)); *written = 0; *ticket = 0;
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease) return SHIROHA_NATIVE_INVALID_INPUT;
  if (lease->ticket || next_ticket_ > INT64_MAX) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  try {
    Sid sid;
    status = check(*lease, sid);
    if (status == SHIROHA_NATIVE_OK && lease->pins.size() != 9) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) {
      status = ops_.association_open(lease->pins[6].handle, sid, lease->target);
      lease->missing = status == SHIROHA_NATIVE_MISSING;
      if (lease->missing && lease->target) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) {
        if (!lease->target || lease->target == INVALID_HANDLE_VALUE) status = SHIROHA_NATIVE_UNAVAILABLE;
        else status = ops_.inspect(lease->target, lease->target_identity);
        if (status == SHIROHA_NATIVE_OK &&
            (!object_valid(lease->target_identity, sid, false, true, true) ||
             lease->target_identity.volume != lease->pins[6].identity.volume)) status = SHIROHA_NATIVE_UNAVAILABLE;
        if (status == SHIROHA_NATIVE_OK) {
          std::vector<uint8_t> bytes;
          status = ops_.read_file(lease->target, bytes);
          if (status == SHIROHA_NATIVE_OK && (bytes.empty() || bytes.size() > SHIROHA_NATIVE_MAX_BYTES))
            status = SHIROHA_NATIVE_DATA_CORRUPT;
          if (status == SHIROHA_NATIVE_OK && bytes.size() > capacity) status = SHIROHA_NATIVE_RESOURCE_LIMIT;
          if (status == SHIROHA_NATIVE_OK) {
            std::memcpy(output, bytes.data(), bytes.size()); *written = bytes.size();
          }
        }
      }
      if (status == SHIROHA_NATIVE_OK || status == SHIROHA_NATIVE_MISSING) {
        const auto original = status;
        status = check(*lease, sid);
        if (status == SHIROHA_NATIVE_OK) status = target_current(*lease, sid);
        if (status == SHIROHA_NATIVE_OK) {
          lease->ticket = next_ticket_++; *ticket = lease->ticket; return original;
        }
      }
    }
  } catch (const std::bad_alloc&) { status = SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { status = SHIROHA_NATIVE_UNAVAILABLE; }
  if (!finish(*lease)) status = SHIROHA_NATIVE_UNAVAILABLE;
  SecureZeroMemory(output, static_cast<SIZE_T>(capacity)); *written = 0;
  return status;
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }

int32_t ProtectedObjects::association_commit(uint32_t version, uint64_t owner,
    uint64_t ticket, const uint8_t* input, uint64_t length) noexcept try {
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!span(input, length)) return SHIROHA_NATIVE_INVALID_INPUT;
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease || !ticket || lease->ticket != ticket) return SHIROHA_NATIVE_INVALID_INPUT;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  bool replacing = false;
  try {
    Sid sid;
    status = check(*lease, sid);
    if (status == SHIROHA_NATIVE_OK) status = target_current(*lease, sid);
    size_t leftovers = 0;
    if (status == SHIROHA_NATIVE_OK) status = ops_.temporary_count(lease->pins[6].handle, leftovers);
    if (status == SHIROHA_NATIVE_OK && leftovers >= 32) status = SHIROHA_NATIVE_RESOURCE_LIMIT;
    std::wstring runtime, random;
    if (status == SHIROHA_NATIVE_OK) status = ops_.random_name(runtime, random);
    if (status == SHIROHA_NATIVE_OK && (!hex(runtime, 16) || !hex(random, 8))) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) {
      if (lease->runtime_id.empty()) lease->runtime_id = runtime;
      const auto name = L"~tmp-" + lease->runtime_id + L"-" + random;
      status = check(*lease, sid);
      if (status == SHIROHA_NATIVE_OK) status = ops_.temporary_create(lease->pins[6].handle, name, sid, lease->temporary);
    }
    if (status == SHIROHA_NATIVE_OK) {
      ObjectInfo temp;
      if (!lease->temporary || lease->temporary == INVALID_HANDLE_VALUE) status = SHIROHA_NATIVE_UNAVAILABLE;
      else status = ops_.inspect(lease->temporary, temp);
      if (status == SHIROHA_NATIVE_OK &&
          (!object_valid(temp, sid, false, true, true) || temp.volume != lease->pins[6].identity.volume)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) status = ops_.write_file(lease->temporary, input, length);
      if (status == SHIROHA_NATIVE_OK) status = ops_.flush_file(lease->temporary);
      if (status == SHIROHA_NATIVE_OK) status = check(*lease, sid);
      if (status == SHIROHA_NATIVE_OK) status = target_current(*lease, sid);
      ObjectInfo current;
      if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(lease->temporary, current);
      if (status == SHIROHA_NATIVE_OK &&
          (!object_valid(current, sid, false, true, true) || current.volume != temp.volume || current.file != temp.file)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) {
        replacing = true;
        status = ops_.replace_file(lease->temporary, lease->pins[6].handle, !lease->missing);
        // A wrapper must explicitly report success; every other replace result
        // is uncertain, irrespective of what the target now appears to contain.
        if (status != SHIROHA_NATIVE_OK) status = SHIROHA_NATIVE_COMMIT_UNKNOWN;
        else {
          // Release the exclusive temp handle before reopening the published
          // name. Failed close or post-publication validation is never success.
          const auto temporary = lease->temporary;
          lease->temporary = nullptr;
          if (!ops_.close(temporary)) {
            lease->denied = true; lease->quarantined = true;
            status = SHIROHA_NATIVE_COMMIT_UNKNOWN;
          } else {
            lease->missing = false; lease->target_identity = temp;
            status = check(*lease, sid);
            if (status == SHIROHA_NATIVE_OK) status = target_current(*lease, sid);
            if (status != SHIROHA_NATIVE_OK) status = SHIROHA_NATIVE_COMMIT_UNKNOWN;
          }
        }
      }
    }
  } catch (const std::bad_alloc&) { status = replacing ? SHIROHA_NATIVE_COMMIT_UNKNOWN : SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { status = replacing ? SHIROHA_NATIVE_COMMIT_UNKNOWN : SHIROHA_NATIVE_UNAVAILABLE; }
  if (!finish(*lease)) status = replacing ? SHIROHA_NATIVE_COMMIT_UNKNOWN : SHIROHA_NATIVE_UNAVAILABLE;
  return status;
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
int32_t ProtectedObjects::association_abort(uint32_t version, uint64_t owner, uint64_t ticket) noexcept try {
  if (version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease || !ticket || lease->ticket != ticket) return SHIROHA_NATIVE_INVALID_INPUT;
  return finish(*lease) ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_UNAVAILABLE;
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}  // namespace shiroha_native
