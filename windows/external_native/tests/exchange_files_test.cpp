#include "protected_objects.h"
#include "exchange_open_policy.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <type_traits>

using namespace shiroha_native;
namespace {
void require(bool ok, const char* label) {
  if (!ok) { std::cerr << "FAIL: " << label << '\n'; std::exit(1); }
}
using Create = int32_t (__cdecl*)(uint32_t, uint64_t, uint32_t, const uint8_t*, const uint8_t*, uint64_t, uint64_t*);
using Read = int32_t (__cdecl*)(uint32_t, uint64_t, uint32_t, const uint8_t*, uint8_t*, uint64_t, uint64_t*);
using ReadBegin = int32_t (__cdecl*)(uint32_t, uint64_t, uint32_t, const uint8_t*, uint8_t*, uint64_t, uint64_t*, uint8_t*);
using Settle = int32_t (__cdecl*)(uint32_t, uint64_t, const uint8_t*);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_create), Create>);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_read), Read>);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_read_begin), ReadBegin>);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_consume), Settle>);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_release), Settle>);
static_assert(!(exchange_access(3) & FILE_READ_DATA));
static_assert((exchange_access(4) & (FILE_READ_DATA | DELETE)) == (FILE_READ_DATA | DELETE));
static_assert(exchange_share(4) == FILE_SHARE_READ);
struct Fake final : ObjectOperations {
  Sid sid{1, 2, 3};
  uintptr_t next = 1;
  uint64_t next_id = 1;
  using Key = std::pair<uint64_t, std::wstring>;
  std::map<Key, ObjectInfo> objects;
  std::map<HANDLE, ObjectInfo> handles;
  std::map<HANDLE, uint32_t> modes;
  std::set<HANDLE> reread;
  std::map<uint64_t, std::vector<uint8_t>> contents;
  std::set<uint64_t> locks;
  std::set<HANDLE> lock_handles;
  bool busy = false, fail_unlock = false, fail_file_close = false;
  std::string fail;
  int mutations = 0, deleted = 0, runtime_opens = 0, exchange_creates = 0, delete_calls = 0, close_calls = 0;
  size_t unknown = 0;
  std::function<void(ObjectInfo&)> damage;
  std::function<void()> on_count, on_read, on_flush;
  ObjectInfo good(bool dir) {
    ObjectInfo i;
    i.file = next_id++; i.volume = 42; i.links = 1;
    i.attributes = dir ? FILE_ATTRIBUTE_DIRECTORY : 0;
    i.drive_type = DRIVE_FIXED; i.filesystem = L"NTFS"; i.owner = sid;
    i.dacl_present = i.dacl_protected = true;
    i.aces.push_back({ACCESS_ALLOWED_ACE_TYPE,
        static_cast<uint8_t>(dir ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE : 0), FILE_ALL_ACCESS, sid});
    return i;
  }
  HANDLE open(const ObjectInfo& i) { auto h = reinterpret_cast<HANDLE>(next++); handles[h] = i; return h; }
  int32_t user_sid(Sid& out) override { out = sid; return 0; }
  int32_t local_directory(HANDLE& out) override {
    const Key key{0, L"LOCAL"};
    if (!objects.count(key)) objects[key] = good(true);
    out = open(objects[key]); return 0;
  }
  int32_t child(HANDLE parent, const wchar_t* name, bool dir, bool create, const Sid&, HANDLE& out) override {
    require(handles.count(parent) == 1, "parent held"); out = nullptr;
    if (std::wstring(name) == L"runtime.lock") ++runtime_opens;
    if (std::wstring(name) == L"exchange" && create) ++exchange_creates;
    const Key key{handles[parent].file, name};
    if (!objects.count(key)) { if (!create) return 4; objects[key] = good(dir); }
    if (!dir && locks.count(objects[key].file)) return 4;
    out = open(objects[key]);
    if (!dir) { locks.insert(objects[key].file); lock_handles.insert(out); }
    return 0;
  }
  int32_t inspect(HANDLE h, ObjectInfo& out) override {
    require(handles.count(h) == 1, "only inspect live handle");
    out = handles[h];
    if (!(out.attributes & FILE_ATTRIBUTE_DIRECTORY) && !lock_handles.count(h) && damage) damage(out);
    return 0;
  }
  bool close(HANDLE h) noexcept override {
    ++close_calls;
    if (!handles.count(h)) std::abort();
    if (fail_file_close && !lock_handles.count(h) && !(handles[h].attributes & FILE_ATTRIBUTE_DIRECTORY)) return false;
    if (lock_handles.erase(h)) locks.erase(handles[h].file);
    handles.erase(h); modes.erase(h); reread.erase(h); return true;
  }
  int32_t exchange_lock(const ObjectInfo&, const Sid&, HANDLE& out) override {
    out = nullptr;
    if (busy || fail == "lock") return 4;
    if (fail == "invalid-lock") { out = INVALID_HANDLE_VALUE; return 0; }
    busy = true; out = reinterpret_cast<HANDLE>(next++); return 0;
  }
  bool exchange_unlock(HANDLE) noexcept override { busy = false; return !fail_unlock; }
  uint64_t exchange_id() const {
    for (const auto& e : objects) if (e.first.second == L"exchange") return e.second.file;
    return 0;
  }
  int32_t exchange_count(HANDLE h, size_t& out) override {
    require(busy && handles[h].file == exchange_id(), "quota inside cross-process exclusion");
    if (on_count) on_count();
    out = unknown;
    for (const auto& e : objects) if (e.first.first == exchange_id()) ++out;
    return fail == "count" ? 4 : 0;
  }
  int32_t exchange_open(HANDLE parent, const std::wstring& name, uint32_t mode, const Sid&, HANDLE& out) override {
    require(busy && handles[parent].file == exchange_id(), "fixed exchange parent under exclusion");
    out = nullptr;
    if (fail == "open" || (mode == 2 && fail == "pin")) return 4;
    const Key key{handles[parent].file, name};
    if (mode == 0) {
      if (objects.count(key)) return 4;
      objects[key] = good(false); ++mutations;
    } else if (!objects.count(key)) return 6;
    const auto compatible = [](ACCESS_MASK access, ULONG share) {
      return (!(access & FILE_READ_DATA) || (share & FILE_SHARE_READ)) &&
          (!(access & FILE_WRITE_DATA) || (share & FILE_SHARE_WRITE)) &&
          (!(access & DELETE) || (share & FILE_SHARE_DELETE));
    };
    for (const auto& m : modes) if (handles[m.first].file == objects[key].file) {
      if (!compatible(exchange_access(mode), exchange_share(m.second)) ||
          !compatible(exchange_access(m.second), exchange_share(mode))) return 4;
    }
    out = open(objects[key]); modes[out] = mode; return 0;
  }
  int32_t exchange_nonce(uint8_t* out, size_t length) override {
    require(length == 16, "bounded random ticket secret");
    if (fail == "nonce") return 4;
    if (fail == "throw-nonce") throw std::runtime_error("synthetic");
    std::fill(out, out + length, static_cast<uint8_t>(next++)); return 0;
  }
  int32_t write_file(HANDLE h, const uint8_t* bytes, uint64_t size) override {
    contents[handles[h].file] = {bytes, bytes + static_cast<size_t>(size)};
    if (fail == "throw-write") throw std::runtime_error("synthetic");
    return fail == "write" ? 4 : 0;
  }
  int32_t flush_file(HANDLE) override { if (on_flush) on_flush(); return fail == "flush" ? 4 : 0; }
  int32_t exchange_read(HANDLE h, size_t maximum, std::vector<uint8_t>& out) override {
    require(busy && (exchange_access(modes[h]) & FILE_READ_DATA), "read on permitted protected handle under lock");
    if (modes[h] == 4) reread.insert(h);
    if (fail == "throw-read") throw std::runtime_error("synthetic");
    out = contents[handles[h].file];
    if (on_read) on_read();
    return fail == "read" ? 4 : out.size() > maximum ? 5 : 0;
  }
  int32_t exchange_delete(HANDLE h) override {
    ++delete_calls;
    require(busy && (exchange_access(modes[h]) & DELETE), "delete serialized on delete-capable handle");
    if (modes[h] == 4) require(reread.count(h) == 1, "consumer rechecks bytes on SAME deletion handle");
    if (fail == "delete") return 4;
    if (fail == "delete-unknown") return 7;
    if (fail == "throw-delete") throw std::runtime_error("synthetic");
    for (auto i = objects.begin(); i != objects.end(); ++i) if (i->second.file == handles[h].file) {
      objects.erase(i); ++deleted;
      if (fail == "throw-after-delete") throw std::runtime_error("synthetic");
      if (fail == "unknown-after-delete") return 7;
      return 0;
    }
    return 4;
  }
};
std::vector<uint8_t> payload(uint32_t kind, const uint8_t* id, size_t size = 105) {
  std::vector<uint8_t> result(size, 0);
  std::memcpy(result.data(), kind == 1 ? "SHREXSUB" : kind == 2 ? "SHREXCHA" : "SHREXPRF", 8);
  result[8] = 1; std::memcpy(result.data() + 9, id, 16); return result;
}
struct Fixture {
  Fake f; ProtectedObjects app_core{f}, bridge_core{f};
  uint64_t app = 0, bridge = 0;
  uint8_t id[16]{};
  Fixture() {
    require(app_core.acquire(3, 1, &app) == 0, "App owner");
    const auto before = f.runtime_opens;
    require(bridge_core.acquire(3, 2, &bridge) == 0 && f.runtime_opens == before, "Bridge never opens runtime.lock");
  }
  ~Fixture() {
    require(app_core.close(3, app) == 0 && bridge_core.close(3, bridge) == 0, "owners close");
    require(f.handles.empty() && !f.busy, "all pins released without delete");
  }
};
struct alignas(8) Ticket { uint8_t bytes[24]{}; };
struct Controlled : Fixture {
  uint64_t receipt = 0;
  Ticket ticket;
  Controlled() {
    auto bytes = payload(1, id);
    require(bridge_core.exchange_create(3, bridge, 1, id, bytes.data(), bytes.size(), &receipt) == 0, "E0 creation");
    require(begin(ticket) == 0, "E0 read begin");
  }
  int32_t begin(Ticket& target) {
    uint8_t out[1024]{}; uint64_t n = 0;
    return app_core.exchange_read_begin(3, app, 1, id, out, 1024, &n, target.bytes);
  }
  void spent() {
    require(app_core.exchange_consume(3, app, ticket.bytes) != 0 &&
        app_core.exchange_release(3, app, ticket.bytes) != 0, "ticket permanently spent");
  }
};
}
int main() {
  for (uint32_t kind : {1u, 2u, 3u}) {
    Fixture x; auto bytes = payload(kind, x.id); uint64_t receipt = 0, written = 0;
    auto& writer = kind == 2 ? x.app_core : x.bridge_core;
    auto& reader = kind == 2 ? x.bridge_core : x.app_core;
    const auto wo = kind == 2 ? x.app : x.bridge, ro = kind == 2 ? x.bridge : x.app;
    const size_t maximum = kind == 1 ? 1024u : kind == 2 ? 4096u : 256u;
    uint8_t out[4096]{};
    require(writer.exchange_create(3, wo, kind, x.id, bytes.data(), bytes.size(), &receipt) == 0 && receipt, "fixed role create");
    const auto saved = receipt;
    require(writer.exchange_create(3, wo, kind, x.id, bytes.data(), bytes.size(), &receipt) != 0 && !receipt, "CREATE_NEW no overwrite");
    require(reader.exchange_read(3, ro, kind, x.id, out, maximum, &written) == 0 && written == bytes.size() &&
        std::equal(bytes.begin(), bytes.end(), out), "counterpart read");
    require(x.f.deleted == 0, "read is not consumption");
    require(reader.exchange_create(3, ro, kind, x.id, bytes.data(), bytes.size(), &receipt) == 1, "role create rejection");
    require(writer.exchange_read(3, wo, kind, x.id, out, maximum, &written) == 1, "role read rejection");
    require(reader.exchange_cleanup(3, ro, saved) == 1, "receipt not transferable");
    require(writer.exchange_cleanup(3, wo, saved) == 0 && x.f.deleted == 1, "creator-only identity cleanup");
    require(writer.exchange_cleanup(3, wo, saved) == 1, "one cleanup attempt");
    require(reader.exchange_read(3, ro, kind, x.id, out, maximum, &written) == 6 && !written, "Missing distinct");
    require(x.f.exchange_creates == 1, "only App initializes exchange");
  }
  for (const auto* stage : {"lock", "invalid-lock", "count", "open", "write", "throw-write", "flush", "pin"}) {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 99;
    x.f.fail = stage;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) != 0 && !receipt, "create fail closed");
    require(x.f.deleted == 0 && !x.f.busy, "failed create never cleans or retains exclusion");
  }
  const std::function<void(ObjectInfo&)> damages[] = {
    [](ObjectInfo& i) { i.owner = {9}; }, [](ObjectInfo& i) { i.dacl_protected = false; },
    [](ObjectInfo& i) { i.aces.clear(); }, [](ObjectInfo& i) { i.aces[0].flags = INHERITED_ACE; },
    [](ObjectInfo& i) { i.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; }, [](ObjectInfo& i) { i.drive_type = DRIVE_REMOTE; },
    [](ObjectInfo& i) { i.filesystem = L"FAT32"; }, [](ObjectInfo& i) { ++i.volume; }, [](ObjectInfo& i) { i.links = 2; }
  };
  for (const auto& damage : damages) {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0;
    x.f.damage = damage;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) != 0 && !receipt, "file recipe rejects");
    require(x.f.deleted == 0, "invalid object untouched");
    x.f.damage = nullptr;
  }
  for (size_t unknown : {31u, 32u, 33u}) {
    Fixture x; x.f.unknown = unknown; auto bytes = payload(1, x.id); uint64_t receipt = 0;
    const auto status = x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt);
    require(unknown == 31 ? status == 0 : status == 4, "unknown objects count toward 32 quota");
    require(x.f.unknown == unknown && x.f.deleted == 0, "quota never sweeps");
  }
  {
    Fixture x; x.f.unknown = 31; uint64_t other_receipt = 0, receipt = 0;
    auto first = payload(1, x.id), second = payload(2, x.id);
    x.f.on_count = [&] {
      require(x.app_core.exchange_create(3, x.app, 2, x.id, second.data(), second.size(), &other_receipt) == 4 && !other_receipt,
          "other process cannot interleave count/create");
    };
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, first.data(), first.size(), &receipt) == 0, "31 to 32 serialized");
    x.f.on_count = nullptr;
    require(x.app_core.exchange_create(3, x.app, 2, x.id, second.data(), second.size(), &other_receipt) == 4, "33rd object denied");
  }
  {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0, written = 5; uint8_t out[1024]{};
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 0, "replacement fixture");
    for (auto& e : x.f.objects) if (e.first.first == x.f.exchange_id()) e.second = x.f.good(false);
    require(x.bridge_core.exchange_cleanup(3, x.bridge, receipt) != 0 && x.f.deleted == 0, "cleanup rejects name replacement");
    require(x.app_core.exchange_read(3, x.app, 1, x.id, out, 1024, &written) == 5 && !written, "incomplete replacement inert");
  }
  for (const auto* stage : {"read", "throw-read", "delete"}) {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0, written = 0; uint8_t out[1024]{};
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 0, "failure fixture");
    x.f.fail = stage;
    if (x.f.fail == "delete") require(x.bridge_core.exchange_cleanup(3, x.bridge, receipt) != 0, "delete failure");
    else require(x.app_core.exchange_read(3, x.app, 1, x.id, out, 1024, &written) != 0 && !written, "read exception zero output");
    require(x.f.deleted == 0 && !x.f.busy, "failure no consumption");
  }
  {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0, written = 0; uint8_t out[1024]{};
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 0, "drift fixture");
    x.f.on_read = [&] { for (auto& h : x.f.handles) if (!x.f.lock_handles.count(h.first) && !(h.second.attributes & FILE_ATTRIBUTE_DIRECTORY)) ++h.second.file; };
    require(x.app_core.exchange_read(3, x.app, 1, x.id, out, 1024, &written) == 4 && !written, "post-read identity drift rejects");
    require(x.bridge_core.exchange_cleanup(3, x.bridge, receipt) == 4 && !x.f.deleted, "retained-pin drift rejects cleanup");
  }
  for (const auto& damage : damages) {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 0, "cleanup security fixture");
    x.f.damage = damage;
    require(x.bridge_core.exchange_cleanup(3, x.bridge, receipt) != 0 && !x.f.deleted, "cleanup rechecks security");
    x.f.damage = nullptr;
  }
  {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0;
    for (auto i = x.f.objects.begin(); i != x.f.objects.end(); ++i) if (i->first.second == L"exchange") {
      x.f.objects.erase(i); break;
    }
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 4 &&
        x.f.exchange_creates == 1 && !x.f.mutations, "Bridge never creates missing exchange");
  }
  {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0;
    for (auto& h : x.f.handles) if (h.second.attributes & FILE_ATTRIBUTE_DIRECTORY) h.second.attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 4 && !x.f.mutations,
        "parent chain rechecked before mutation");
  }
  for (uint32_t kind : {1u, 2u, 3u}) {
    Fixture x; uint64_t receipt = 0;
    const size_t maximum = kind == 1 ? 1024u : kind == 2 ? 4096u : 256u;
    auto bytes = payload(kind, x.id, maximum);
    auto& core = kind == 2 ? x.app_core : x.bridge_core;
    auto owner = kind == 2 ? x.app : x.bridge;
    require(core.exchange_create(3, owner, kind, x.id, bytes.data(), bytes.size(), &receipt) == 0, "raw native exact byte cap");
    bytes.push_back(0);
    require(core.exchange_create(3, owner, kind, x.id, bytes.data(), bytes.size(), &receipt) == 1 && !receipt, "raw native cap+1 rejects");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, receipt = 0; uint8_t id[16]{};
    require(core.acquire(3, 1, &owner) == 0 && core.close(3, owner) == 0, "closed owner fixture");
    auto bytes = payload(2, id);
    require(core.exchange_create(3, owner, 2, id, bytes.data(), bytes.size(), &receipt) == 1 && f.handles.empty(), "stale owner denies before access");
  }
  {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 9;
    bytes[9] = 1;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 1 && !receipt && !x.f.mutations, "ID mismatch before OS");
    bytes[9] = 0;
    require(x.bridge_core.exchange_create(2, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 2, "new calls require ABI3");
    require(x.bridge_core.exchange_create(3, 999, 1, x.id, bytes.data(), bytes.size(), &receipt) == 1, "unknown owner");
    require(x.bridge_core.exchange_create(3, x.bridge, 4, x.id, bytes.data(), bytes.size(), &receipt) == 1, "no credential kind through exchange");
  }
  for (uint32_t kind : {1u, 2u, 3u}) {
    Fixture x; auto bytes = payload(kind, x.id); uint64_t receipt = 0, n = 0;
    auto& writer = kind == 2 ? x.app_core : x.bridge_core;
    auto& reader = kind == 2 ? x.bridge_core : x.app_core;
    auto wo = kind == 2 ? x.app : x.bridge, ro = kind == 2 ? x.bridge : x.app;
    const size_t maximum = kind == 1 ? 1024 : kind == 2 ? 4096 : 256;
    uint8_t out[4096]{}; Ticket ticket, released;
    require(writer.exchange_create(3, wo, kind, x.id, bytes.data(), bytes.size(), &receipt) == 0, "E0 fixed creator");
    require(reader.exchange_read_begin(3, ro, kind, x.id, out, maximum, &n, released.bytes) == 0 &&
        n == bytes.size() && std::equal(bytes.begin(), bytes.end(), out), "E0 exact read bytes");
    require(reader.exchange_release(3, ro, released.bytes) == 0 && !x.f.deleted, "release preserves file");
    require(reader.exchange_release(3, ro, released.bytes) == 1 && reader.exchange_consume(3, ro, released.bytes) == 1, "release once");
    require(writer.exchange_read_begin(3, wo, kind, x.id, out, maximum, &n, ticket.bytes) == 1, "E0 wrong role");
    require(reader.exchange_read_begin(3, ro, kind, x.id, out, maximum, &n, ticket.bytes) == 0, "E0 reread");
    ProtectedObjects competing_owner(x.f); uint64_t competing = 0;
    require(competing_owner.acquire(3, kind == 2 ? 2u : 1u, &competing) != 0 && !competing,
        "second process cannot bypass existing consumer role writer ownership");
    require(reader.exchange_consume(3, ro, ticket.bytes) == 0 && x.f.deleted == 1 && x.f.delete_calls == 1, "counterpart consumes with creator pin still held");
    require(reader.exchange_consume(3, ro, ticket.bytes) == 1, "consume once");
    require(writer.exchange_cleanup(3, wo, receipt) != 0 && x.f.delete_calls == 1, "creator cleanup after consumption cannot delete another object");
  }
  {
    Controlled x; auto forged = x.ticket; forged.bytes[8] ^= 1;
    Ticket zero;
    require(x.app_core.exchange_consume(3, x.app, forged.bytes) == 1 &&
        x.app_core.exchange_release(3, x.app, zero.bytes) == 1 &&
        x.bridge_core.exchange_consume(3, x.bridge, x.ticket.bytes) == 1 &&
        x.app_core.exchange_consume(3, 999, x.ticket.bytes) == 1, "forgery and cross owner reject");
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 0, "forgery never redirects or consumes valid capability");
    x.spent();
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t app = 0, bridge = 0, receipt = 0, n = 0;
    uint8_t id[16]{}, out[1024]{}; Ticket ticket;
    require(core.acquire(3, 1, &app) == 0 && core.acquire(3, 2, &bridge) == 0 && app != bridge, "two distinct owners in one registry");
    auto bytes = payload(1, id);
    require(core.exchange_create(3, bridge, 1, id, bytes.data(), bytes.size(), &receipt) == 0 &&
        core.exchange_read_begin(3, app, 1, id, out, 1024, &n, ticket.bytes) == 0, "same-registry cross-owner fixture");
    require(core.exchange_consume(3, bridge, ticket.bytes) == 1 && core.exchange_release(3, bridge, ticket.bytes) == 1 && !f.delete_calls,
        "known wrong owner cannot consume or release original consumer ticket");
    require(core.exchange_release(3, app, ticket.bytes) == 0 && core.close(3, app) == 0 && core.close(3, bridge) == 0 && f.handles.empty(),
        "original consumer retains release authority");
  }
  for (int mutation : {0, 1, 2, 3, 4}) {
    Controlled x;
    for (auto& e : x.f.objects) if (e.first.first == x.f.exchange_id()) {
      if (mutation == 0) e.second = x.f.good(false); // Same name, new identity.
      else if (mutation == 1) x.f.contents[e.second.file][30] ^= 1; // SAME file ID, different bytes.
      else if (mutation == 2) x.f.contents[e.second.file].resize(24);
      else if (mutation == 3) x.f.contents[e.second.file].assign(1025, 0);
    }
    if (mutation == 4) {
      for (auto it = x.f.objects.begin(); it != x.f.objects.end(); ++it)
        if (it->first.first == x.f.exchange_id()) { x.f.objects.erase(it); break; }
    }
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && !x.f.delete_calls, "replacement/change/truncation/oversize/removal denies before delete");
    x.spent();
  }
  for (const auto& damage : damages) {
    Controlled x; x.f.damage = damage;
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && !x.f.delete_calls, "consumer rechecks pin and object security");
    x.spent(); x.f.damage = nullptr;
  }
  for (const auto* stage : {"lock", "invalid-lock", "count", "open", "read", "throw-read", "delete"}) {
    Controlled x; x.f.fail = stage;
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && !x.f.deleted && !x.f.busy, "consume injected failure closes and spends");
    x.spent();
  }
  for (const auto* stage : {"delete-unknown", "throw-delete", "throw-after-delete", "unknown-after-delete"}) {
    Controlled x; x.f.fail = stage;
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 7 && x.f.delete_calls == 1, "unknown deletion reports unknown exactly once");
    x.spent();
  }
  for (const auto* stage : {"nonce", "throw-nonce", "pin", "read", "throw-read"}) {
    Fixture x; auto bytes = payload(1, x.id); uint64_t receipt = 0, n = 7;
    uint8_t out[1024]; std::fill(out, out + 1024, static_cast<uint8_t>(9)); Ticket ticket;
    require(x.bridge_core.exchange_create(3, x.bridge, 1, x.id, bytes.data(), bytes.size(), &receipt) == 0, "read failure fixture");
    x.f.fail = stage;
    require(x.app_core.exchange_read_begin(3, x.app, 1, x.id, out, 1024, &n, ticket.bytes) != 0 &&
        !n && std::all_of(out, out + 1024, [](auto v) { return !v; }) &&
        std::all_of(ticket.bytes, ticket.bytes + 24, [](auto v) { return !v; }), "read failure clears all outputs");
    require(!x.f.deleted && !x.f.busy, "read failure never deletes or holds mutex");
  }
  {
    Controlled x; Ticket other;
    require(x.begin(other) == 0, "two pending reads share pins");
    x.f.on_read = [&] {
      require(x.bridge_core.exchange_cleanup(3, x.bridge, x.receipt) == 4, "competing process cleanup cannot enter consumer mutex");
    };
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 0, "winner consumes under exclusion");
    x.f.on_read = nullptr;
    require(x.app_core.exchange_consume(3, x.app, other.bytes) != 0 && x.f.deleted == 1 && x.f.delete_calls == 1, "only one competing read can consume");
  }
  {
    Controlled x; uint64_t other_receipt = 0;
    const auto proof = payload(3, x.id);
    x.f.on_count = [&] {
      require(x.bridge_core.exchange_create(3, x.bridge, 3, x.id, proof.data(), proof.size(), &other_receipt) == 4 && !other_receipt,
          "other process cannot interleave creation during consumer quota/identity/content/delete decision");
    };
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 0 && x.f.deleted == 1 && x.f.mutations == 1,
        "consumer exclusion covers concurrent create without broadening roles");
    x.f.on_count = nullptr;
  }
  {
    Controlled x;
    require(x.bridge_core.exchange_cleanup(3, x.bridge, x.receipt) == 0, "P24 cleanup compatible with reader pin");
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && x.f.deleted == 1, "cleanup winner prevents consumption");
  }
  {
    Controlled x; ObjectInfo identity;
    for (const auto& e : x.f.objects) if (e.first.first == x.f.exchange_id()) identity = e.second;
    const auto writer = x.f.open(identity); x.f.modes[writer] = 0;
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 4 && !x.f.delete_calls,
        "outstanding write handle cannot share the consumer read-delete decision");
    require(x.f.close(writer), "synthetic external writer closes"); x.spent();
  }
  for (size_t unknown : {31u, 32u}) {
    Controlled x; x.f.unknown = unknown;
    require((x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 0) == (unknown == 31), "consume at 32 allowed, above 32 denied without sweep");
  }
  {
    Controlled x; Ticket tickets[32];
    for (size_t i = 0; i < 31; ++i) require(x.begin(tickets[i]) == 0, "bounded repeated read capacity");
    require(x.begin(tickets[31]) == 3, "33rd reader ticket denied");
    require(x.app_core.exchange_release(3, x.app, x.ticket.bytes) == 0 && x.begin(tickets[31]) == 0, "release frees capacity");
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) == 1 && !x.f.deleted, "freed slot cannot revive old serial");
  }
  {
    Controlled x;
    for (auto& h : x.f.handles) if (h.second.attributes & FILE_ATTRIBUTE_DIRECTORY) ++h.second.file;
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && !x.f.delete_calls, "parent identity drift before consume denies");
    x.spent();
  }
  {
    Controlled x;
    x.f.on_read = [&] { for (auto& h : x.f.handles) if (h.second.attributes & FILE_ATTRIBUTE_DIRECTORY) h.second.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; };
    require(x.app_core.exchange_consume(3, x.app, x.ticket.bytes) != 0 && !x.f.delete_calls, "post-reread parent drift before deletion denies");
    x.spent();
  }
  {
    Controlled x; uint8_t out[1024]{}; uint64_t n = 7; Ticket t;
    require(x.app_core.exchange_read_begin(2, x.app, 1, x.id, out, 1024, &n, t.bytes) == 2 && !n, "E0 requires ABI3");
    require(x.app_core.exchange_read_begin(3, x.app, 1, x.id, out, 1024, &n, out) == 1, "ticket/output alias rejects");
    require(x.app_core.exchange_read_begin(3, x.app, 1, x.id, out, 1024, reinterpret_cast<uint64_t*>(t.bytes), t.bytes) == 1, "ticket/count alias rejects");
    require(x.app_core.exchange_release(3, x.app, t.bytes + 1) == 1, "unaligned ticket rejects");
    require(x.app_core.exchange_read_begin(3, x.app, 1, x.id, out, 1000, &n, t.bytes) == 1, "E0 exact bounded capacity");
  }
  for (bool consume : {false, true}) {
    Fake f;
    {
      ProtectedObjects app(f), bridge(f); uint64_t a = 0, b = 0, receipt = 0, n = 0;
      uint8_t id[16]{}, out[1024]{}; Ticket t;
      require(app.acquire(3, 1, &a) == 0 && bridge.acquire(3, 2, &b) == 0, "release failure owners");
      auto bytes = payload(1, id);
      require(bridge.exchange_create(3, b, 1, id, bytes.data(), bytes.size(), &receipt) == 0 &&
          app.exchange_read_begin(3, a, 1, id, out, 1024, &n, t.bytes) == 0, "release failure read");
      f.fail_file_close = true;
      require((consume ? app.exchange_consume(3, a, t.bytes) : app.exchange_release(3, a, t.bytes)) == (consume ? 7 : 4), "close failure is unknown or unavailable");
      const auto calls = f.close_calls;
      require(app.close(3, a) == 4 && app.exchange_release(3, a, t.bytes) != 0 && f.close_calls == calls, "quarantine never retries uncertain handles");
      f.fail_file_close = false;
      require(bridge.close(3, b) == 0, "other owner stays isolated");
    }
    require(!consume ? f.deleted == 0 : f.deleted == 1, "release never deletes; post-delete close failure never undoes/retries delete");
  }
  for (int stage : {0, 1, 2}) {
    Fake f; ProtectedObjects core(f); uint64_t app = 0, bridge = 0, receipt = 0, n = 0;
    uint8_t id[16]{}, out[1024]{}; Ticket live, unpublished;
    auto bytes = payload(1, id);
    require(core.acquire(3, 1, &app) == 0 && core.acquire(3, 2, &bridge) == 0 &&
        core.exchange_create(3, bridge, 1, id, bytes.data(), bytes.size(), &receipt) == 0 &&
        core.exchange_read_begin(3, app, 1, id, out, 1024, &n, live.bytes) == 0, "terminal release fixture");
    if (stage == 0) {
      f.fail_file_close = true;
      require(core.exchange_read_begin(3, app, 1, id, out, 1024, &n, unpublished.bytes) == 4 && !n,
          "read handle close failure returns no ticket");
    } else if (stage == 1) {
      f.fail_unlock = true;
      require(core.exchange_consume(3, app, live.bytes) == 7 && f.deleted == 1 && f.delete_calls == 1,
          "post-delete mutex release failure is unknown with no retry");
    } else {
      f.fail_file_close = true;
      require(core.close(3, app) == 4 && !f.deleted, "OwnerClose reader pin failure never deletes");
    }
    const auto before = f.close_calls;
    require(core.close(3, app) == 4 && core.exchange_release(3, app, live.bytes) == 4 && f.close_calls == before,
        "all uncertain releases quarantine without another close");
    f.fail_file_close = false; f.fail_unlock = false;
    require(core.close(3, bridge) == 0, "quarantine does not affect another owner");
  }
  {
    Controlled x;
    for (auto& e : x.f.objects) if (e.first.first == x.f.exchange_id()) x.f.contents[e.second.file][9] ^= 1;
    Ticket bad; uint8_t out[1024]{}; uint64_t n = 99;
    require(x.app_core.exchange_read_begin(3, x.app, 1, x.id, out, 1024, &n, bad.bytes) == 5 && !n,
        "native fixed internal ID rejects before minting ticket");
    require(x.app_core.exchange_release(3, x.app, x.ticket.bytes) == 0 && !x.f.deleted, "invalid content remains untouched");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t app = 0, bridge = 0, receipt = 0, n = 0;
    uint8_t id[16]{}, out[1024]{}; Ticket live, t;
    auto bytes = payload(1, id);
    require(core.acquire(3, 1, &app) == 0 && core.acquire(3, 2, &bridge) == 0 &&
        core.exchange_create(3, bridge, 1, id, bytes.data(), bytes.size(), &receipt) == 0 &&
        core.exchange_read_begin(3, app, 1, id, out, 1024, &n, live.bytes) == 0, "mutex release failure fixture");
    f.fail_unlock = true;
    require(core.exchange_read_begin(3, app, 1, id, out, 1024, &n, t.bytes) == 4 && !n,
        "read mutex release failure denies output and quarantines");
    auto before = f.close_calls;
    require(core.exchange_release(3, app, live.bytes) == 4 && f.close_calls == before,
        "quarantined owner cannot release other live ticket handles");
    f.fail_unlock = false;
    require(core.close(3, app) == 4 && !f.deleted && core.close(3, bridge) == 0,
        "quarantine close fails without deletion, other owner unaffected");
  }
  std::cout << "PASS: P24/E0 fake-only Exchange identity/content/one-use contracts; REAL WINDOWS PENDING\n";
}
