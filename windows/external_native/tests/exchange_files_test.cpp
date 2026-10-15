#include "protected_objects.h"
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
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_create), Create>);
static_assert(std::is_same_v<decltype(&shiroha_native_exchange_read), Read>);
struct Fake final : ObjectOperations {
  Sid sid{1, 2, 3};
  uintptr_t next = 1;
  uint64_t next_id = 1;
  using Key = std::pair<uint64_t, std::wstring>;
  std::map<Key, ObjectInfo> objects;
  std::map<HANDLE, ObjectInfo> handles;
  std::map<uint64_t, std::vector<uint8_t>> contents;
  std::set<uint64_t> locks;
  std::set<HANDLE> lock_handles;
  bool busy = false, fail_unlock = false, fail_file_close = false;
  std::string fail;
  int mutations = 0, deleted = 0, runtime_opens = 0, exchange_creates = 0;
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
    if (!handles.count(h)) std::abort();
    if (fail_file_close && !lock_handles.count(h) && !(handles[h].attributes & FILE_ATTRIBUTE_DIRECTORY)) return false;
    if (lock_handles.erase(h)) locks.erase(handles[h].file);
    handles.erase(h); return true;
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
    out = open(objects[key]); return 0;
  }
  int32_t write_file(HANDLE h, const uint8_t* bytes, uint64_t size) override {
    contents[handles[h].file] = {bytes, bytes + static_cast<size_t>(size)};
    if (fail == "throw-write") throw std::runtime_error("synthetic");
    return fail == "write" ? 4 : 0;
  }
  int32_t flush_file(HANDLE) override { if (on_flush) on_flush(); return fail == "flush" ? 4 : 0; }
  int32_t exchange_read(HANDLE h, size_t maximum, std::vector<uint8_t>& out) override {
    if (fail == "throw-read") throw std::runtime_error("synthetic");
    out = contents[handles[h].file];
    if (on_read) on_read();
    return fail == "read" ? 4 : out.size() > maximum ? 5 : 0;
  }
  int32_t exchange_delete(HANDLE h) override {
    require(busy, "delete serialized");
    if (fail == "delete") return 4;
    for (auto i = objects.begin(); i != objects.end(); ++i) if (i->second.file == handles[h].file) {
      objects.erase(i); ++deleted; return 0;
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
  std::cout << "PASS: P24 fake-only Exchange contracts; REAL WINDOWS PENDING\n";
}
