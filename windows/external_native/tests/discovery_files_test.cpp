#include "protected_objects.h"
#include "discovery_rename.h"
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
void require(bool ok, const char* label) { if (!ok) { std::cerr << "FAIL: " << label << '\n'; std::exit(1); } }
using Publish = int32_t(__cdecl*)(uint32_t, uint64_t, uint32_t, const uint8_t*, uint64_t);
using Read = int32_t(__cdecl*)(uint32_t, uint64_t, uint32_t, uint8_t*, uint64_t, uint64_t*);
static_assert(std::is_same_v<decltype(&shiroha_native_discovery_publish), Publish>);
static_assert(std::is_same_v<decltype(&shiroha_native_discovery_read), Read>);
struct Fake final : ObjectOperations {
  Sid sid{1, 2, 3};
  uintptr_t next_handle = 1;
  uint64_t next_id = 1;
  using Key = std::pair<uint64_t, std::wstring>;
  std::map<Key, ObjectInfo> objects;
  std::map<HANDLE, ObjectInfo> handles;
  std::map<uint64_t, std::vector<uint8_t>> contents;
  std::set<uint64_t> locked;
  std::set<HANDLE> lock_handles;
  std::vector<std::string> events;
  std::string fail;
  int runtime_opens = 0, discovery_creates = 0, sequence = 0;
  size_t leftovers = 0;
  bool published = false, collision = false, replace_read = false;
  std::function<void(ObjectInfo&)> damage;
  ObjectInfo good(bool dir) {
    ObjectInfo i; i.file = next_id++; i.volume = 42; i.links = 1;
    i.attributes = dir ? FILE_ATTRIBUTE_DIRECTORY : 0; i.drive_type = DRIVE_FIXED;
    i.filesystem = L"NTFS"; i.owner = sid; i.dacl_present = i.dacl_protected = true;
    i.aces.push_back({ACCESS_ALLOWED_ACE_TYPE, static_cast<uint8_t>(dir ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE : 0), FILE_ALL_ACCESS, sid});
    return i;
  }
  HANDLE open(ObjectInfo i) { auto h = reinterpret_cast<HANDLE>(next_handle++); handles[h] = i; return h; }
  uint64_t directory() { for (const auto& e : objects) if (e.first.second == L"discovery") return e.second.file; return 0; }
  int32_t user_sid(Sid& out) override { out = sid; return fail == "sid" ? 4 : 0; }
  int32_t local_directory(HANDLE& out) override { if (!objects.count({0, L"LOCAL"})) objects[{0, L"LOCAL"}] = good(true); out = open(objects[{0, L"LOCAL"}]); return 0; }
  int32_t child(HANDLE p, const wchar_t* name, bool dir, bool create, const Sid&, HANDLE& out) override {
    require(handles.count(p) == 1, "live parent"); out = nullptr;
    if (std::wstring(name) == L"runtime.lock") ++runtime_opens;
    if (std::wstring(name) == L"discovery" && create) ++discovery_creates;
    Key k{handles[p].file, name};
    if (!objects.count(k)) { if (!create) return 4; objects[k] = good(dir); }
    if (!dir && locked.count(objects[k].file)) return 4;
    out = open(objects[k]); if (!dir) { locked.insert(objects[k].file); lock_handles.insert(out); } return 0;
  }
  int32_t inspect(HANDLE h, ObjectInfo& out) override {
    require(handles.count(h) == 1, "inspect held identity"); out = handles[h];
    if (damage) damage(out);
    if (published && fail == "post") ++out.file;
    return 0;
  }
  bool close(HANDLE h) noexcept override {
    if (!handles.count(h)) std::abort();
    if (lock_handles.erase(h)) locked.erase(handles[h].file);
    handles.erase(h); return true;
  }
  int32_t discovery_open(HANDLE p, uint32_t kind, HANDLE& out) override {
    require(handles[p].file == directory(), "fixed discovery parent"); out = nullptr;
    Key k{directory(), discovery_name(kind)};
    if (!objects.count(k)) return 6;
    if (fail == "open") return 4;
    out = open(objects[k]); return 0;
  }
  int32_t temporary_count(HANDLE p, size_t& out) override { require(handles[p].file == directory(), "count fixed directory"); out = leftovers; return 0; }
  int32_t random_name(std::wstring& runtime, std::wstring& random) override {
    runtime = L"0123456789abcdef"; random = L"00000000"; random.back() = static_cast<wchar_t>(L'0' + sequence++); return 0;
  }
  int32_t temporary_create(HANDLE p, const std::wstring& name, const Sid&, HANDLE& out) override {
    require(name.rfind(L"~tmp-0123456789abcdef-", 0) == 0, "runtime temp grammar");
    require(handles[p].file == directory(), "relative CREATE_NEW");
    if (collision) return 4;
    Key k{directory(), name}; require(!objects.count(k), "no overwrite temp");
    objects[k] = good(false); out = open(objects[k]); events.push_back("create"); return 0;
  }
  int32_t write_file(HANDLE h, const uint8_t* p, uint64_t n) override {
    events.push_back("write"); contents[handles[h].file] = {p, p + static_cast<size_t>(n)}; return fail == "write" ? 4 : 0;
  }
  int32_t flush_file(HANDLE) override { events.push_back("flush"); return fail == "flush" ? 4 : 0; }
  int32_t exchange_read(HANDLE h, size_t max, std::vector<uint8_t>& out) override {
    out = contents[handles[h].file];
    if (replace_read) objects[{directory(), L"endpoint.bin"}] = good(false);
    return out.size() > max ? 5 : 0;
  }
  int32_t discovery_replace(HANDLE h, HANDLE p, uint32_t kind, bool replace) override {
    events.push_back("rename"); require(handles[p].file == directory(), "relative rename");
    Key k{directory(), discovery_name(kind)};
    require(replace == (kind == 1 && objects.count(k)), "only endpoint replace");
    if (fail == "rename") return 7;
    const auto info = handles[h];
    for (auto i = objects.begin(); i != objects.end(); ++i) if (i->second.file == info.file) { objects.erase(i); break; }
    objects[k] = info; published = true;
    if (fail == "throw-rename") throw std::runtime_error("synthetic");
    return 0;
  }
};
NTSTATUS NTAPI renamed(HANDLE, PIO_STATUS_BLOCK io, PVOID value, ULONG size, FILE_INFORMATION_CLASS cls) {
  const auto* info = static_cast<AssociationRenameBase*>(value);
  require(static_cast<int>(cls) == 10 && size >= sizeof(AssociationRenameBase) + info->FileNameLength, "rename NT layout");
  require(info->RootDirectory == reinterpret_cast<HANDLE>(2), "verified parent in rename");
  io->Status = 0;
  return 0;
}
struct Fixture {
  Fake f; ProtectedObjects core{f}; uint64_t app = 0, bridge = 0;
  Fixture() { require(core.acquire(3, 1, &app) == 0, "App lock"); const auto n = f.runtime_opens; require(core.acquire(3, 2, &bridge) == 0 && f.runtime_opens == n, "Bridge own lock only"); }
  ~Fixture() { require(core.close(3, app) == 0 && core.close(3, bridge) == 0 && f.handles.empty(), "release all handles"); }
};
}
int main() {
  for (uint32_t kind = 1; kind <= 3; ++kind) {
    Fixture x; const size_t size = kind == 1 ? 185 : kind == 2 ? 512 : 36;
    std::vector<uint8_t> data(size, 42), output(kind == 2 ? 1024 : size, 99); uint64_t written = 99;
    require(x.core.discovery_read(3, x.bridge, kind, output.data(), output.size(), &written) == 6 && written == 0 && output[0] == 0, "Missing clears output");
    require(x.core.discovery_publish(3, x.bridge, kind, data.data(), data.size()) == 1, "Bridge cannot publish");
    require(x.core.discovery_publish(3, x.app, kind, data.data(), data.size()) == 0, "publish fixed object");
    require(x.f.events == std::vector<std::string>({"create", "write", "flush", "rename"}), "production core ordering");
    require(x.core.discovery_read(3, x.bridge, kind, output.data(), output.size(), &written) == 0 && written == size && std::memcmp(output.data(), data.data(), size) == 0, "Bridge verified read");
    const auto before = x.f.events.size();
    require(x.core.discovery_publish(3, x.app, kind, data.data(), data.size()) == 0, "equal identity publication");
    if (kind != 1) { require(before == x.f.events.size(), "anchor/id never replaced"); data[0] ^= 1; require(x.core.discovery_publish(3, x.app, kind, data.data(), data.size()) == 5, "mismatched identity never overwritten"); }
    require(x.f.discovery_creates == 1, "Bridge never creates directory");
    require(rename_discovery(renamed, reinterpret_cast<HANDLE>(1), reinterpret_cast<HANDLE>(2), kind, kind == 1) == 0, "NT rename layout");
  }
  for (auto stage : {"write", "flush", "rename", "throw-rename", "post"}) {
    Fixture x; x.f.fail = stage; uint8_t data[185]{};
    const auto result = x.core.discovery_publish(3, x.app, 1, data, sizeof(data));
    const bool unknown = x.f.fail == "rename" || x.f.fail == "throw-rename" || x.f.fail == "post";
    require(result == (unknown ? 7 : 4), "typed failure and uncertain publication");
    const auto count = x.f.objects.size();
    require(count >= 1, "no cleanup on failure");
    if (unknown) require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 4 && x.f.objects.size() == count, "unknown permanently denies owner mutation");
  }
  for (int corruption = 0; corruption < 9; ++corruption) {
    Fixture x; uint8_t data[185]{};
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 0, "seed");
    x.f.damage = [corruption](ObjectInfo& i) {
      switch (corruption) { case 0: i.owner = {9}; break; case 1: i.aces.clear(); break;
        case 2: i.dacl_protected = false; break; case 3: i.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; break;
        case 4: i.drive_type = DRIVE_REMOTE; break; case 5: i.filesystem = L"FAT"; break;
        case 6: ++i.file; break; case 7: ++i.volume; break; case 8: i.links = 2; break; }
    };
    uint64_t written = 0;
    require(x.core.discovery_read(3, x.bridge, 1, data, sizeof(data), &written) != 0 && written == 0, "security/parent/identity hard denial");
    x.f.damage = nullptr;
  }
  for (int corruption = 0; corruption < 6; ++corruption) {
    Fixture x; uint8_t data[185]{}; uint64_t written = 0;
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 0, "seed file security");
    x.f.damage = [&x, corruption](ObjectInfo& i) {
      if ((i.attributes & FILE_ATTRIBUTE_DIRECTORY) || x.f.locked.count(i.file)) return;
      switch (corruption) { case 0: i.owner = {9}; break; case 1: i.aces.clear(); break;
        case 2: i.dacl_protected = false; break; case 3: i.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; break;
        case 4: ++i.volume; break; case 5: i.links = 2; break; }
    };
    require(x.core.discovery_read(3, x.bridge, 1, data, sizeof(data), &written) == 4 && written == 0, "file security distinct from parent checks");
    x.f.damage = nullptr;
  }
  { Fixture x; uint8_t data[185]{};
    x.f.damage = [&x](ObjectInfo& i) { if (x.f.locked.count(i.file)) ++i.file; };
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 4 && x.f.events.empty(), "lost App lock prevents temp creation");
    x.f.damage = nullptr; }
  { Fixture x; uint8_t data[185]{}; uint64_t written = 0;
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 0, "seed replacement");
    x.f.replace_read = true;
    require(x.core.discovery_read(3, x.bridge, 1, data, sizeof(data), &written) == 4 && written == 0, "read replacement not hidden by reread"); }
  { Fixture x; uint8_t data[185]{}; x.f.leftovers = 32;
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 3 && x.f.events.empty(), "bounded leftovers untouched");
    x.f.leftovers = 0; x.f.collision = true;
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 4 && x.f.events.empty(), "collision no retry");
    require(x.core.discovery_publish(3, 999, 1, data, sizeof(data)) == 1, "invalid owner"); }
  { Fixture x; uint8_t data[185]{};
    const Fake::Key sentinel{x.f.directory(), L"foreign-sentinel"}; x.f.objects[sentinel] = x.f.good(false);
    const auto identity = x.f.objects[sentinel].file;
    require(x.core.discovery_publish(3, x.app, 1, data, sizeof(data)) == 0 && x.f.objects[sentinel].file == identity, "foreign sentinel preserved"); }
  std::cout << "PASS: Discovery production core with synthetic operations only\n";
}
