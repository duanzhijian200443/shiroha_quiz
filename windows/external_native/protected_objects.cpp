#include "protected_objects.h"
#include <limits>

namespace shiroha_native {
bool local_nt_name(const std::wstring& path, std::wstring& result) {
  result.clear();
  if (path.size() < 3 || path.size() > 32762 ||
      !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) ||
      path[1] != L':' || path[2] != L'\\') return false;
  for (size_t i = 2; i < path.size(); ++i) {
    const auto c = static_cast<uint16_t>(path[i]);
    if (c < 32 || c == L':' || c == L'/' || c == L'\0' ||
        c == L'*' || c == L'?' || c == L'"' || c == L'<' || c == L'>' || c == L'|') return false;
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (++i >= path.size() || path[i] < 0xDC00 || path[i] > 0xDFFF) return false;
    } else if (c >= 0xDC00 && c <= 0xDFFF) return false;
  }
  size_t start = 3;
  while (start < path.size()) {
    const auto end = path.find(L'\\', start);
    const auto component = path.substr(start, end == std::wstring::npos ? end : end - start);
    if (component.empty() || component == L"." || component == L"..") return false;
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  result = L"\\??\\" + path;
  return true;
}

bool safe_component(const std::wstring& name) noexcept {
  if (name.empty() || name.size() > 64 || name == L"." || name == L"..") return false;
  for (auto c : name) {
    if (c < 32 || c == L'\\' || c == L'/' || c == L':' || c == L'\0' ||
        c == L'*' || c == L'?' || c == L'"' || c == L'<' || c == L'>' || c == L'|') return false;
  }
  return name.back() != L'.' && name.back() != L' ';
}

bool object_valid(const ObjectInfo& i, const Sid& sid, bool directory,
                  bool check_owner, bool check_dacl) noexcept {
  if (sid.empty() || i.filesystem != L"NTFS" || i.drive_type != DRIVE_FIXED ||
      i.file == 0 || (i.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      ((i.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory ||
      (!directory && i.links != 1) || (check_owner && i.owner != sid)) return false;
  if (!check_dacl) return true;
  if (!i.dacl_present || !i.dacl_protected || i.aces.size() != 1) return false;
  const auto& ace = i.aces[0];
  const auto flags = directory ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE : 0;
  return ace.type == ACCESS_ALLOWED_ACE_TYPE && ace.flags == flags &&
      ace.mask == FILE_ALL_ACCESS && ace.sid == sid;
}

bool ProtectedObjects::release(Lease& lease) noexcept {
  bool ok = finish(lease);
  for (auto& read : lease.exchange_reads) {
    if (read.pin && !ops_.close(read.pin)) ok = false;
    read.pin = nullptr;
    read.token = 0;
    SecureZeroMemory(read.nonce.data(), read.nonce.size());
    read.bytes.clear();
  }
  for (auto& receipt : lease.exchange_receipts) {
    if (receipt.pin && !ops_.close(receipt.pin)) ok = false;
    receipt.pin = nullptr;
    receipt.token = 0;
  }
  if (lease.exchange.handle && lease.exchange.handle != INVALID_HANDLE_VALUE &&
      !ops_.close(lease.exchange.handle)) ok = false;
  lease.exchange.handle = nullptr;
  if (lease.discovery.handle && lease.discovery.handle != INVALID_HANDLE_VALUE &&
      !ops_.close(lease.discovery.handle)) ok = false;
  lease.discovery.handle = nullptr;
  // The lock is inserted after root/Bridge and before store directories.
  // No operations can use this denied lease; close every held OS handle once.
  for (auto it = lease.pins.rbegin(); it != lease.pins.rend(); ++it) {
    if (it->handle && it->handle != INVALID_HANDLE_VALUE) {
      if (ops_.close(it->handle)) it->handle = nullptr;
      else ok = false;
    }
  }
  lease.denied = true;
  lease.quarantined = !ok;
  return ok;
}

ProtectedObjects::~ProtectedObjects() noexcept {
  for (auto& lease : owners_) {
    if (lease && !lease->quarantined) release(*lease);
    // A failed CloseHandle is unknown ownership: never retry a possibly stale
    // HANDLE value. Quarantine consumes a slot until process teardown.
  }
}

int32_t ProtectedObjects::add(Lease& lease, HANDLE parent, const wchar_t* name,
                              bool directory, const Sid& sid, bool dacl, bool create) {
  if (!name || !safe_component(name)) return SHIROHA_NATIVE_INVALID_INPUT;
  const auto parents = inspect_pins(lease, sid);
  if (parents != SHIROHA_NATIVE_OK) return parents;
  // pins was reserved before any native acquisition, so emplacement cannot
  // strand a newly returned handle. Inspector exceptions also leave it owned.
  lease.pins.emplace_back();
  auto& pin = lease.pins.back();
  pin.owner = true;
  pin.dacl = dacl;
  auto status = ops_.child(parent, name, directory,
      create && mode_ == OpenMode::initialize, sid, pin.handle);
  if (status != SHIROHA_NATIVE_OK) return status;
  if (!pin.handle || pin.handle == INVALID_HANDLE_VALUE) return SHIROHA_NATIVE_UNAVAILABLE;
  status = ops_.inspect(pin.handle, pin.identity);
  if (status != SHIROHA_NATIVE_OK) return status;
  if (!object_valid(pin.identity, sid, directory, true, dacl) ||
      pin.identity.volume != lease.pins.front().identity.volume) return SHIROHA_NATIVE_UNAVAILABLE;
  return SHIROHA_NATIVE_OK;
}

int32_t ProtectedObjects::inspect_pins(Lease& lease, const Sid& sid) {
  for (auto& pin : lease.pins) {
    ObjectInfo current;
    const auto status = ops_.inspect(pin.handle, current);
    if (status != SHIROHA_NATIVE_OK) return status;
    const bool directory = (pin.identity.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    if (!object_valid(current, sid, directory, pin.owner, pin.dacl) ||
        current.volume != pin.identity.volume || current.file != pin.identity.file)
      return SHIROHA_NATIVE_UNAVAILABLE;
  }
  return SHIROHA_NATIVE_OK;
}

int32_t ProtectedObjects::acquire(uint32_t version, uint32_t role,
                                 uint64_t* token) noexcept {
  if (!token || reinterpret_cast<uintptr_t>(token) % alignof(uint64_t) != 0 ||
      reinterpret_cast<uintptr_t>(token) > (std::numeric_limits<uintptr_t>::max)() - sizeof(*token))
    return SHIROHA_NATIVE_INVALID_INPUT;
  *token = 0;
  if (version != 2u && version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (role != SHIROHA_NATIVE_APP && role != SHIROHA_NATIVE_BRIDGE) return SHIROHA_NATIVE_INVALID_INPUT;
  try {
    std::lock_guard<std::mutex> guard(mutex_);
    size_t slot = 0;
    while (slot < owners_.size() && owners_[slot]) ++slot;
    if (slot == owners_.size() || next_token_ > INT64_MAX) return SHIROHA_NATIVE_RESOURCE_LIMIT;
    auto lease = std::make_unique<Lease>();
    lease->pins.reserve(12);
    lease->token = next_token_++;
    lease->role = role;
    owners_[slot] = std::move(lease);
    auto& held = *owners_[slot];
    int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
    try {
      Sid sid;
      status = ops_.user_sid(sid);
      if (status == SHIROHA_NATIVE_OK && sid.empty()) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) {
        held.pins.emplace_back();
        auto& root = held.pins.back();
        root.owner = false; root.dacl = false; // Known Folder accepted as-is.
        status = ops_.local_directory(root.handle);
        if (status == SHIROHA_NATIVE_OK && (!root.handle || root.handle == INVALID_HANDLE_VALUE))
          status = SHIROHA_NATIVE_UNAVAILABLE;
        if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(root.handle, root.identity);
        if (status == SHIROHA_NATIVE_OK && !object_valid(root.identity, sid, true, false, false))
          status = SHIROHA_NATIVE_UNAVAILABLE;
      }
      if (status == SHIROHA_NATIVE_OK) status = add(held, held.pins.back().handle, L"Shiroha", true, sid, false, role == SHIROHA_NATIVE_APP);
      if (status == SHIROHA_NATIVE_OK) status = add(held, held.pins.back().handle, L"external", true, sid, true, role == SHIROHA_NATIVE_APP);
      const auto external = status == SHIROHA_NATIVE_OK ? held.pins.back().handle : nullptr;
      if (status == SHIROHA_NATIVE_OK && role == SHIROHA_NATIVE_BRIDGE)
        status = add(held, external, L"bridge", true, sid, true);
      if (status == SHIROHA_NATIVE_OK)
        status = add(held, held.pins.back().handle,
                     role == SHIROHA_NATIVE_APP ? L"runtime.lock" : L"client.lock", false, sid, true);
      // Only a successful OS-exclusive lock precedes any store directory work.
      if (status == SHIROHA_NATIVE_OK && role == SHIROHA_NATIVE_APP) {
        status = add(held, external, L"app", true, sid, true);
        const auto app = status == SHIROHA_NATIVE_OK ? held.pins.back().handle : nullptr;
        if (status == SHIROHA_NATIVE_OK) status = add(held, app, L"trust", true, sid, true);
        if (status == SHIROHA_NATIVE_OK) status = add(held, app, L"state", true, sid, true);
        if (status == SHIROHA_NATIVE_OK) status = add(held, external, L"discovery", true, sid, true);
        if (status == SHIROHA_NATIVE_OK) status = add(held, external, L"exchange", true, sid, true);
      }
      if (status == SHIROHA_NATIVE_OK) status = inspect_pins(held, sid);
    } catch (const std::bad_alloc&) { status = SHIROHA_NATIVE_RESOURCE_LIMIT; }
      catch (...) { status = SHIROHA_NATIVE_UNAVAILABLE; }
    if (status == SHIROHA_NATIVE_OK) { *token = held.token; return status; }
    if (release(held)) owners_[slot].reset();
    return status;
  } catch (const std::bad_alloc&) { return SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}

int32_t ProtectedObjects::validate(uint32_t version, uint64_t token) noexcept {
  if (version != 2u && version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!token) return SHIROHA_NATIVE_INVALID_INPUT;
  try {
    std::lock_guard<std::mutex> guard(mutex_);
    for (auto& lease : owners_) if (lease && lease->token == token) {
      if (lease->denied) return SHIROHA_NATIVE_UNAVAILABLE;
      // Denial remains permanent even if attributes later become valid again.
      lease->denied = true;
      Sid sid;
      auto status = ops_.user_sid(sid);
      if (status == SHIROHA_NATIVE_OK) status = inspect_pins(*lease, sid);
      lease->denied = status != SHIROHA_NATIVE_OK;
      return status;
    }
    return SHIROHA_NATIVE_INVALID_INPUT;
  } catch (const std::bad_alloc&) { return SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}

int32_t ProtectedObjects::close(uint32_t version, uint64_t token) noexcept {
  if (version != 2u && version != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!token) return SHIROHA_NATIVE_INVALID_INPUT;
  try {
    std::lock_guard<std::mutex> guard(mutex_);
    for (auto& lease : owners_) if (lease && lease->token == token) {
      if (lease->quarantined) return SHIROHA_NATIVE_UNAVAILABLE;
      if (!release(*lease)) return SHIROHA_NATIVE_UNAVAILABLE;
      lease.reset();
      return SHIROHA_NATIVE_OK;
    }
    return SHIROHA_NATIVE_INVALID_INPUT;
  } catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}
}  // namespace shiroha_native
