#include "protected_objects.h"
#include <cstdlib>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>

using namespace shiroha_native;
namespace {
void check(bool ok, const char* name) {
  if (!ok) { std::cerr << "FAIL: " << name << '\n'; std::exit(1); }
}
struct Fake final : ObjectOperations {
  Sid sid{1, 2, 3}; // Synthetic, never passed to an OS security API.
  uintptr_t next_handle = 1;
  uint64_t next_file = 1;
  std::map<HANDLE, ObjectInfo> handles;
  std::map<std::pair<uint64_t, std::wstring>, ObjectInfo> objects;
  std::set<uint64_t> locked;
  std::vector<std::wstring> calls;
  std::map<HANDLE, bool> is_lock;
  std::wstring fail_name, corrupt_name;
  bool throw_inspect = false, throw_child = false, fail_close = false;
  bool change_identity = false;
  int closes = 0;
  std::function<void(ObjectInfo&)> corrupt;
  ObjectInfo good(bool dir) {
    ObjectInfo i;
    i.volume = 42; i.file = next_file++; i.attributes = dir ? FILE_ATTRIBUTE_DIRECTORY : 0;
    i.drive_type = DRIVE_FIXED; i.filesystem = L"NTFS"; i.links = 1;
    i.owner = sid; i.dacl_present = true; i.dacl_protected = true;
    i.aces.push_back({ACCESS_ALLOWED_ACE_TYPE,
        static_cast<uint8_t>(dir ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE : 0), FILE_ALL_ACCESS, sid});
    return i;
  }
  int32_t user_sid(Sid& out) override { out = sid; return SHIROHA_NATIVE_OK; }
  HANDLE handle(const ObjectInfo& i, bool exclusive) {
    const auto h = reinterpret_cast<HANDLE>(next_handle++);
    handles[h] = i; is_lock[h] = exclusive;
    if (exclusive) locked.insert(i.file);
    return h;
  }
  int32_t local_directory(HANDLE& out) override {
    calls.push_back(L"LOCAL");
    auto key = std::make_pair(uint64_t{0}, std::wstring{L"LOCAL"});
    if (!objects.count(key)) objects[key] = good(true);
    out = handle(objects[key], false);
    return SHIROHA_NATIVE_OK;
  }
  int32_t child(HANDLE parent, const wchar_t* name, bool dir, bool create, const Sid&, HANDLE& out) override {
    calls.push_back(name);
    out = nullptr;
    check(handles.count(parent) == 1, "parent is still held");
    if (fail_name == name) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto key = std::make_pair(handles[parent].file, std::wstring{name});
    if (!create && !objects.count(key)) return SHIROHA_NATIVE_UNAVAILABLE;
    if (!objects.count(key)) objects[key] = good(dir);
    auto info = objects[key];
    if (corrupt_name == name && corrupt) corrupt(info);
    if (!dir && locked.count(info.file)) return SHIROHA_NATIVE_UNAVAILABLE;
    out = handle(info, !dir);
    if (throw_child) throw std::runtime_error("synthetic");
    return SHIROHA_NATIVE_OK;
  }
  int32_t inspect(HANDLE h, ObjectInfo& out) override {
    check(handles.count(h) == 1, "inspect held object");
    if (throw_inspect) throw std::runtime_error("synthetic");
    out = handles[h];
    if (change_identity) ++out.file;
    return SHIROHA_NATIVE_OK;
  }
  bool close(HANDLE h) noexcept override {
    ++closes;
    if (fail_close) return false;
    if (!handles.count(h)) std::abort();
    if (is_lock[h]) locked.erase(handles[h].file);
    handles.erase(h); is_lock.erase(h);
    return true;
  }
};
}  // namespace

int main() {
  std::wstring nt_name;
  const std::wstring unicode_path = L"C:\\synthetic user\\\x5408\x6210 \xD83D\xDE00";
  check(local_nt_name(unicode_path, nt_name) && nt_name == L"\\??\\" + unicode_path, "Unicode and spaces preserve native name");
  for (const auto* path : {L"relative", L"\\\\server\\share", L"\\\\?\\C:\\x", L"C:\\..\\x", L"C:\\x:y", L"C:\\a\\\\b", L"C:\\\xD800", L"C:\\\xDC00"})
    check(!local_nt_name(path, nt_name) && nt_name.empty(), "unsafe known-folder name denied before native open");
  for (const auto* name : {L"", L".", L"..", L"a\\b", L"a/b", L"a:b", L"\\??\\x", L"a.", L"a ", L"*"})
    check(!safe_component(name), "unsafe single component rejected");
  check(!safe_component(std::wstring(L"a\0b", 3)), "embedded nul rejected");
  check(safe_component(L"runtime.lock") && safe_component(L"client.lock"), "fixed components accepted");
  {
    Fake f; ProtectedObjects core(f); uint64_t token = 99;
    check(core.acquire(2, 2, &token) == SHIROHA_NATIVE_UNAVAILABLE && token == 0,
          "Bridge must not create the App-owned root");
    check(f.calls == std::vector<std::wstring>({L"LOCAL", L"Shiroha"}) && f.handles.empty(),
          "absent App root denies Bridge before its directory/lock");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t token = 99;
    check(core.acquire(1, 1, &token) == SHIROHA_NATIVE_ABI_MISMATCH && token == 0 && f.calls.empty(), "ABI before any IO");
    check(core.acquire(2, 3, &token) == SHIROHA_NATIVE_INVALID_INPUT && f.calls.empty(), "role before IO");
    check(core.acquire(2, 1, nullptr) == SHIROHA_NATIVE_INVALID_INPUT, "null output");
    alignas(8) uint8_t bytes[16]{};
    check(core.acquire(2, 1, reinterpret_cast<uint64_t*>(bytes + 1)) == SHIROHA_NATIVE_INVALID_INPUT, "unaligned output");
    check(core.acquire(2, 1, &token) == 0 && token != 0, "App owner");
    check(f.calls == std::vector<std::wstring>({L"LOCAL", L"Shiroha", L"external", L"runtime.lock", L"app", L"trust", L"state", L"discovery", L"exchange"}), "lock before store directories");
    check(core.validate(2, token) == 0, "held identity validation");
    const auto before = f.calls.size();
    uint64_t competitor = 99;
    check(core.acquire(2, 1, &competitor) == SHIROHA_NATIVE_UNAVAILABLE && competitor == 0, "App contention");
    check(f.calls.size() == before + 4 && f.handles.size() == 9, "no store operation after failed lock and cleanup");
    uint64_t bridge = 0;
    check(core.acquire(2, 2, &bridge) == 0 && f.locked.size() == 2, "separate Bridge owner");
    check(core.acquire(2, 2, &competitor) == SHIROHA_NATIVE_UNAVAILABLE && competitor == 0, "Bridge contention");
    check(core.close(2, bridge) == 0 && core.close(2, token) == 0 && f.handles.empty(), "OS handles released");
    check(core.close(2, token) == SHIROHA_NATIVE_INVALID_INPUT && core.validate(2, token) == SHIROHA_NATIVE_INVALID_INPUT, "retired token cannot revive");
    uint64_t replacement = 0;
    check(core.acquire(2, 1, &replacement) == 0 && replacement != token, "repeat init fresh ownership");
    // Changing pathname lookup state does not change a held parent/lock. All
    // validation inspects captured handles, with no path reopen or recreation.
    f.objects.clear();
    check(core.validate(2, replacement) == 0, "path substitution does not redirect held handles");
    f.change_identity = true;
    check(core.validate(2, replacement) == SHIROHA_NATIVE_UNAVAILABLE, "identity change denied");
    f.change_identity = false;
    check(core.validate(2, replacement) == SHIROHA_NATIVE_UNAVAILABLE, "denial permanent");
    check(core.close(2, replacement) == 0, "denied owner still closes");
  }
  const std::vector<std::function<void(ObjectInfo&)>> negatives{
    [](auto& i) { i.owner = {9}; },
    [](auto& i) { i.dacl_present = false; },
    [](auto& i) { i.dacl_protected = false; },
    [](auto& i) { i.aces.clear(); },
    [](auto& i) { i.aces.push_back(i.aces[0]); },
    [](auto& i) { i.aces[0].type = ACCESS_DENIED_ACE_TYPE; },
    [](auto& i) { i.aces[0].flags |= INHERITED_ACE; },
    [](auto& i) { i.aces[0].flags = 0; },
    [](auto& i) { i.aces[0].sid = {9}; },
    [](auto& i) { i.aces[0].mask = FILE_GENERIC_READ; },
    [](auto& i) { i.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; },
    [](auto& i) { i.attributes = 0; },
    [](auto& i) { i.drive_type = DRIVE_REMOTE; },
    [](auto& i) { i.drive_type = DRIVE_REMOVABLE; },
    [](auto& i) { i.drive_type = DRIVE_UNKNOWN; },
    [](auto& i) { i.filesystem = L"FAT32"; },
    [](auto& i) { i.volume = 7; },
    [](auto& i) { i.file = 0; }
  };
  for (const auto& negative : negatives) {
    Fake f; ProtectedObjects core(f); f.corrupt_name = L"external"; f.corrupt = negative;
    uint64_t token = 99;
    check(core.acquire(2, 1, &token) == SHIROHA_NATIVE_UNAVAILABLE && token == 0 && f.handles.empty(), "bad protected directory fails before lock");
    check(f.calls.back() == L"external", "no later IO after directory failure");
  }
  for (const auto* name : {L"Shiroha", L"external", L"runtime.lock", L"app", L"trust", L"state", L"discovery", L"exchange"}) {
    Fake f; ProtectedObjects core(f); f.fail_name = name; uint64_t token = 99;
    check(core.acquire(2, 1, &token) == SHIROHA_NATIVE_UNAVAILABLE && token == 0 && f.handles.empty(), "partial acquire releases all handles");
    // Compliant created empty directories remain; no deletion/ACL repair seam.
    f.fail_name.clear();
    check(core.acquire(2, 1, &token) == 0, "partial creation can be revalidated explicitly");
    check(core.close(2, token) == 0, "close after repeat creation");
  }
  for (const auto* name : {L"Shiroha", L"runtime.lock", L"client.lock"}) {
    Fake f; ProtectedObjects core(f); f.corrupt_name = name;
    f.corrupt = [](auto& i) { i.attributes |= FILE_ATTRIBUTE_REPARSE_POINT; };
    uint64_t token = 0;
    if (name == std::wstring(L"client.lock")) {
      check(core.acquire(2, 1, &token) == 0 && core.close(2, token) == 0, "App prepares Bridge root");
    }
    check(core.acquire(2, name == std::wstring(L"client.lock") ? 2 : 1, &token) == SHIROHA_NATIVE_UNAVAILABLE && f.handles.empty(), "parent/lock reparse rejection");
  }
  {
    Fake f; ProtectedObjects core(f); f.corrupt_name = L"runtime.lock";
    f.corrupt = [](auto& i) { i.links = 2; }; uint64_t token = 0;
    check(core.acquire(2, 1, &token) == SHIROHA_NATIVE_UNAVAILABLE && f.handles.empty(), "lock hard-link alias denied");
  }
  for (const bool child : {false, true}) {
    Fake f; ProtectedObjects core(f); f.throw_child = child; f.throw_inspect = !child;
    uint64_t token = 99;
    check(core.acquire(2, 1, &token) == SHIROHA_NATIVE_UNAVAILABLE && token == 0 && f.handles.empty(), "exception after handle acquisition cleans ownership");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t token = 0;
    check(core.acquire(2, 1, &token) == 0, "owner before close failure");
    f.fail_close = true;
    check(core.close(2, token) == SHIROHA_NATIVE_UNAVAILABLE, "unknown release quarantines");
    const auto closes = f.closes;
    check(core.validate(2, token) == SHIROHA_NATIVE_UNAVAILABLE && core.close(2, token) == SHIROHA_NATIVE_UNAVAILABLE && f.closes == closes, "quarantine never retries stale handles");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t token = 0;
    // Distinct synthetic installations permit exercising registry capacity;
    // this is not a fake substitute for production OS exclusion.
    for (size_t i = 0; i < ProtectedObjects::max_owners; ++i) {
      f.objects.erase({0, L"LOCAL"});
      check(core.acquire(2, 1, &token) == 0, "bounded registry owner");
    }
    const auto calls = f.calls.size();
    check(core.acquire(2, 1, &token) == SHIROHA_NATIVE_RESOURCE_LIMIT && token == 0 && f.calls.size() == calls, "capacity fails before IO");
  }
  std::cout << "PASS: fake-only protected-object policy, identity, lock ordering and lifetime\n";
}
