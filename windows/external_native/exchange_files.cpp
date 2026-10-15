#include "protected_objects.h"
#include <cstring>
#include <limits>

namespace shiroha_native {
namespace {
bool span(const void* p, uint64_t n) noexcept {
  return p && n && n <= SHIROHA_NATIVE_MAX_BYTES &&
      reinterpret_cast<uintptr_t>(p) <= (std::numeric_limits<uintptr_t>::max)() - n;
}
bool count(uint64_t* p) noexcept { return span(p, 8) && reinterpret_cast<uintptr_t>(p) % 8 == 0; }
bool overlaps(const void* a, uint64_t n, const void* b, uint64_t m) noexcept {
  const auto x = reinterpret_cast<uintptr_t>(a), y = reinterpret_cast<uintptr_t>(b);
  return x < y + m && y < x + n;
}
size_t cap(uint32_t kind) noexcept { return kind == 1 ? 1024u : kind == 2 ? 4096u : kind == 3 ? 256u : 0u; }
std::wstring filename(uint32_t kind, const uint8_t* id) {
  std::wstring result = kind == 1 ? L"submission-" : kind == 2 ? L"pairing-" : L"proof-";
  constexpr wchar_t digits[] = L"0123456789abcdef";
  for (size_t i = 0; i < 16; ++i) { result += digits[id[i] >> 4]; result += digits[id[i] & 15]; }
  return result + (kind == 1 ? L".pub" : kind == 2 ? L".chal" : L".bin");
}
bool same(const ObjectInfo& a, const ObjectInfo& b) noexcept { return a.volume == b.volume && a.file == b.file; }
// This only binds the fixed I/O header/ID; full parsing remains P22-only in Dart.
bool header(uint32_t kind, const uint8_t* id, const uint8_t* bytes, size_t size) noexcept {
  const char* magic = kind == 1 ? "SHREXSUB" : kind == 2 ? "SHREXCHA" : "SHREXPRF";
  return size >= 25 && size <= cap(kind) && std::memcmp(bytes, magic, 8) == 0 &&
      bytes[8] == 1 && std::memcmp(bytes + 9, id, 16) == 0;
}
}

int32_t ProtectedObjects::exchange_directory(Lease& lease, Sid& sid) {
  auto status = check(lease, sid);
  if (status != SHIROHA_NATIVE_OK) return status;
  auto& pin = lease.exchange;
  if (!pin.handle) {
    // App already created exchange; Bridge must NEVER create or repair it.
    status = ops_.child(lease.pins[2].handle, L"exchange", true, false, sid, pin.handle);
    if (status != SHIROHA_NATIVE_OK) return status;
    if (!pin.handle || pin.handle == INVALID_HANDLE_VALUE) return SHIROHA_NATIVE_UNAVAILABLE;
    status = ops_.inspect(pin.handle, pin.identity);
    if (status != SHIROHA_NATIVE_OK) return status;
  }
  ObjectInfo current;
  status = ops_.inspect(pin.handle, current);
  if (status == SHIROHA_NATIVE_OK && (!object_valid(current, sid, true, true, true) ||
      !same(current, pin.identity) || current.volume != lease.pins[2].identity.volume ||
      (lease.role == SHIROHA_NATIVE_APP && !same(current, lease.pins[8].identity))))
    status = SHIROHA_NATIVE_UNAVAILABLE;
  if (status != SHIROHA_NATIVE_OK) lease.denied = true;
  return status;
}

int32_t ProtectedObjects::exchange_operation(uint64_t owner, uint32_t kind, const uint8_t* id,
    const uint8_t* input, uint64_t length, uint8_t* output, uint64_t capacity,
    uint64_t* written, uint64_t* receipt, bool create) {
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease) return SHIROHA_NATIVE_INVALID_INPUT;
  const uint32_t writer = kind == 2 ? SHIROHA_NATIVE_APP : SHIROHA_NATIVE_BRIDGE;
  if (create ? lease->role != writer : lease->role == writer) return SHIROHA_NATIVE_INVALID_INPUT;
  ExchangeReceipt* slot = nullptr;
  if (create) {
    for (auto& r : lease->exchange_receipts) if (!r.token && !r.pin) { slot = &r; break; }
    if (!slot || next_ticket_ > INT64_MAX) return SHIROHA_NATIVE_RESOURCE_LIMIT;
  }
  HANDLE lock = nullptr, file = nullptr, pin = nullptr;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  ObjectInfo identity;
  std::wstring name;
  std::vector<uint8_t> bytes;
  try {
    Sid sid;
    name = filename(kind, id);
    status = exchange_directory(*lease, sid);
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_lock(lease->exchange.identity, sid, lock);
    if (status == SHIROHA_NATIVE_OK && (!lock || lock == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = exchange_directory(*lease, sid);
    size_t entries = 0;
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_count(lease->exchange.handle, entries);
    if (status == SHIROHA_NATIVE_OK && (entries > 32 || (create && entries == 32))) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK)
      status = ops_.exchange_open(lease->exchange.handle, name, create ? 0u : 1u, sid, file);
    if (status == SHIROHA_NATIVE_OK && (!file || file == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(file, identity);
    if (status == SHIROHA_NATIVE_OK && (!object_valid(identity, sid, false, true, true) ||
        identity.volume != lease->exchange.identity.volume)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK && create) status = ops_.write_file(file, input, length);
    if (status == SHIROHA_NATIVE_OK && create) status = ops_.flush_file(file);
    if (status == SHIROHA_NATIVE_OK && !create) status = ops_.exchange_read(file, cap(kind), bytes);
    if (status == SHIROHA_NATIVE_OK && !create &&
        (!header(kind, id, bytes.data(), bytes.size()) || bytes.size() > capacity)) status = SHIROHA_NATIVE_DATA_CORRUPT;
    ObjectInfo after;
    if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(file, after);
    if (status == SHIROHA_NATIVE_OK && (!object_valid(after, sid, false, true, true) || !same(after, identity)))
      status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = exchange_directory(*lease, sid);
    // Retain an independent read-only identity pin before closing the creator's
    // write handle, so file indices cannot be recycled into cleanup authority.
    if (status == SHIROHA_NATIVE_OK && create) {
      status = ops_.exchange_open(lease->exchange.handle, name, 2, sid, pin);
      ObjectInfo pinned;
      if (status == SHIROHA_NATIVE_OK && (!pin || pin == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
      if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(pin, pinned);
      if (status == SHIROHA_NATIVE_OK && (!object_valid(pinned, sid, false, true, true) || !same(pinned, identity)))
        status = SHIROHA_NATIVE_UNAVAILABLE;
    }
  } catch (const std::bad_alloc&) { status = SHIROHA_NATIVE_RESOURCE_LIMIT; }
    catch (...) { status = SHIROHA_NATIVE_UNAVAILABLE; }
  bool closed = true;
  if (file && file != INVALID_HANDLE_VALUE && !ops_.close(file)) closed = false;
  if (lock && lock != INVALID_HANDLE_VALUE && !ops_.exchange_unlock(lock)) closed = false;
  if (!closed) { lease->denied = true; lease->quarantined = true; status = SHIROHA_NATIVE_UNAVAILABLE; }
  if (status == SHIROHA_NATIVE_OK && create) {
    slot->identity = std::move(identity); slot->name = std::move(name);
    slot->pin = pin; slot->token = next_ticket_++; *receipt = slot->token;
  } else {
    if (pin && pin != INVALID_HANDLE_VALUE && !ops_.close(pin)) {
      lease->denied = true; lease->quarantined = true; status = SHIROHA_NATIVE_UNAVAILABLE;
    }
    if (status == SHIROHA_NATIVE_OK) { std::memcpy(output, bytes.data(), bytes.size()); *written = bytes.size(); }
  }
  return status;
}

int32_t ProtectedObjects::exchange_create(uint32_t version, uint64_t owner, uint32_t kind,
    const uint8_t* id, const uint8_t* input, uint64_t length, uint64_t* receipt) noexcept try {
  if (!span(id, 16) || !span(input, length) || !count(receipt) ||
      overlaps(id, 16, input, length) || overlaps(id, 16, receipt, 8) || overlaps(input, length, receipt, 8))
    return SHIROHA_NATIVE_INVALID_INPUT;
  *receipt = 0;
  if (version != 3) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!cap(kind) || !header(kind, id, input, static_cast<size_t>(length))) return SHIROHA_NATIVE_INVALID_INPUT;
  return exchange_operation(owner, kind, id, input, length, nullptr, 0, nullptr, receipt, true);
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }

int32_t ProtectedObjects::exchange_read(uint32_t version, uint64_t owner, uint32_t kind,
    const uint8_t* id, uint8_t* output, uint64_t capacity, uint64_t* written) noexcept try {
  if (!span(id, 16) || !span(output, capacity) || !count(written) ||
      overlaps(id, 16, output, capacity) || overlaps(id, 16, written, 8) || overlaps(output, capacity, written, 8))
    return SHIROHA_NATIVE_INVALID_INPUT;
  SecureZeroMemory(output, static_cast<SIZE_T>(capacity)); *written = 0;
  if (version != 3) return SHIROHA_NATIVE_ABI_MISMATCH;
  if (!cap(kind) || capacity != cap(kind)) return SHIROHA_NATIVE_INVALID_INPUT;
  return exchange_operation(owner, kind, id, nullptr, 0, output, capacity, written, nullptr, false);
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }

int32_t ProtectedObjects::exchange_cleanup(uint32_t version, uint64_t owner, uint64_t receipt) noexcept try {
  if (version != 3) return SHIROHA_NATIVE_ABI_MISMATCH;
  std::lock_guard<std::mutex> guard(mutex_);
  auto* lease = find(owner);
  if (!lease || !receipt) return SHIROHA_NATIVE_INVALID_INPUT;
  ExchangeReceipt* slot = nullptr;
  for (auto& r : lease->exchange_receipts) if (r.token == receipt) { slot = &r; break; }
  if (!slot) return SHIROHA_NATIVE_INVALID_INPUT;
  slot->token = 0; // One attempt, including failure. No path deletion retry.
  HANDLE lock = nullptr, file = nullptr;
  int32_t status = SHIROHA_NATIVE_UNAVAILABLE;
  try {
    Sid sid;
    status = exchange_directory(*lease, sid);
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_lock(lease->exchange.identity, sid, lock);
    if (status == SHIROHA_NATIVE_OK && (!lock || lock == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
    ObjectInfo held, current;
    if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(slot->pin, held);
    if (status == SHIROHA_NATIVE_OK && (!object_valid(held, sid, false, true, true) || !same(held, slot->identity))) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_open(lease->exchange.handle, slot->name, 3, sid, file);
    if (status == SHIROHA_NATIVE_OK && (!file || file == INVALID_HANDLE_VALUE)) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = ops_.inspect(file, current);
    if (status == SHIROHA_NATIVE_OK && (!object_valid(current, sid, false, true, true) || !same(current, slot->identity))) status = SHIROHA_NATIVE_UNAVAILABLE;
    if (status == SHIROHA_NATIVE_OK) status = exchange_directory(*lease, sid);
    if (status == SHIROHA_NATIVE_OK) status = ops_.exchange_delete(file);
  } catch (...) { status = SHIROHA_NATIVE_UNAVAILABLE; }
  bool closed = true;
  if (file && file != INVALID_HANDLE_VALUE && !ops_.close(file)) closed = false;
  if (slot->pin && !ops_.close(slot->pin)) closed = false;
  slot->pin = nullptr;
  if (lock && lock != INVALID_HANDLE_VALUE && !ops_.exchange_unlock(lock)) closed = false;
  if (!closed) { lease->denied = true; lease->quarantined = true; status = SHIROHA_NATIVE_UNAVAILABLE; }
  return status;
} catch (...) { return SHIROHA_NATIVE_UNAVAILABLE; }
}  // namespace shiroha_native
