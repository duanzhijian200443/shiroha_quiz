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
  std::wstring fail_stage;
  size_t leftovers = 0;
  bool unknown_after_replace = false, lock_lost_on_flush = false, target_changed_on_flush = false;
  bool temp_corrupt = false, collision = false;
  bool throw_after_replace = false;
  bool fail_published_close = false, corrupt_published_identity = false;
  bool fail_finish_after_replace = false;
  bool fail_old_target_close = false;
  HANDLE old_target = nullptr;
  int old_target_closes = 0, rename_calls = 0;
  HANDLE renamed = nullptr;
  std::map<uint64_t, std::vector<uint8_t>> contents;
  std::vector<std::wstring> file_events;
  HANDLE state = nullptr;
  HANDLE flushed = nullptr;
  int32_t association_open(HANDLE parent, const Sid&, HANDLE& out) override {
    state = parent; out = nullptr;
    file_events.push_back(L"open");
    check(handles.count(parent) == 1, "association parent held");
    if (fail_stage == L"open") return SHIROHA_NATIVE_UNAVAILABLE;
    const auto key = std::make_pair(handles[parent].file, std::wstring{L"associations.bin"});
    if (!objects.count(key)) return SHIROHA_NATIVE_MISSING;
    out = handle(objects[key], false);
    return SHIROHA_NATIVE_OK;
  }
  int32_t read_file(HANDLE file, std::vector<uint8_t>& out) override {
    file_events.push_back(L"read");
    if (fail_stage == L"read") return SHIROHA_NATIVE_UNAVAILABLE;
    out = contents[handles[file].file]; return SHIROHA_NATIVE_OK;
  }
  int32_t temporary_count(HANDLE, size_t& out) override {
    file_events.push_back(L"count"); out = leftovers;
    return fail_stage == L"count" ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK;
  }
  int32_t random_name(std::wstring& runtime, std::wstring& random) override {
    runtime = L"0123456789abcdef"; random = L"01234567";
    return fail_stage == L"random" ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK;
  }
  int32_t temporary_create(HANDLE parent, const std::wstring& name, const Sid&, HANDLE& out) override {
    file_events.push_back(L"create"); out = nullptr;
    check(name == L"~tmp-0123456789abcdef-01234567", "frozen temporary name");
    if (fail_stage == L"create" || collision) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto key = std::make_pair(handles[parent].file, name);
    if (objects.count(key)) return SHIROHA_NATIVE_UNAVAILABLE;
    objects[key] = good(false);
    if (temp_corrupt) objects[key].attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
    out = handle(objects[key], false); return SHIROHA_NATIVE_OK;
  }
  int32_t write_file(HANDLE h, const uint8_t* input, uint64_t length) override {
    file_events.push_back(L"write");
    contents[handles[h].file] = std::vector<uint8_t>(input, input + static_cast<size_t>(length));
    return fail_stage == L"write" ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK;
  }
  int32_t flush_file(HANDLE file) override {
    file_events.push_back(L"flush");
    if (lock_lost_on_flush) for (auto& item : handles) if (is_lock[item.first]) item.second.file++;
    if (target_changed_on_flush) {
      const auto key = std::make_pair(handles[state].file, std::wstring{L"associations.bin"});
      objects[key] = good(false);
    }
    if (fail_stage == L"flush") return SHIROHA_NATIVE_UNAVAILABLE;
    flushed = file;
    return SHIROHA_NATIVE_OK;
  }
  int32_t replace_file(HANDLE h, HANDLE parent, bool existing) override {
    ++rename_calls;
    check(flushed == h, "completed Flush precedes atomic replace");
    check(handles.count(parent) == 1 && !locked.empty(), "parent and writer lock remain held at rename");
    file_events.push_back(existing ? L"replace-existing" : L"replace-new");
    const auto key = std::make_pair(handles[parent].file, std::wstring{L"associations.bin"});
    if (objects.count(key)) {
      for (const auto& held : handles) {
        if (held.second.file == objects[key].file) return SHIROHA_NATIVE_COMMIT_UNKNOWN;
      }
    }
    if (fail_stage == L"replace") {
      if (fail_finish_after_replace) renamed = h;
      return SHIROHA_NATIVE_COMMIT_UNKNOWN;
    }
    const auto identity = handles[h];
    check(objects.count(key) == static_cast<size_t>(existing), "replace existence matches validated snapshot");
    for (auto it = objects.begin(); it != objects.end();) {
      if (it->second.file == identity.file) it = objects.erase(it); else ++it;
    }
    objects[key] = identity;
    renamed = h;
    if (corrupt_published_identity) ++objects[key].file;
    if (throw_after_replace) throw std::runtime_error("synthetic");
    return unknown_after_replace ? SHIROHA_NATIVE_COMMIT_UNKNOWN : SHIROHA_NATIVE_OK;
  }
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
    if (h == old_target) {
      ++old_target_closes;
      file_events.push_back(L"close-old-target");
      if (fail_old_target_close) return false;
    }
    if (h == renamed && (fail_published_close || fail_finish_after_replace)) return false;
    if (fail_close) return false;
    if (!handles.count(h)) std::abort();
    if (is_lock[h]) locked.erase(handles[h].file);
    handles.erase(h); is_lock.erase(h);
    return true;
  }
};
}  // namespace

int main() {
  for (const bool fail_old_close : {false, true}) {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
    uint8_t output[64]{}, input[]{4, 5, 6};
    check(core.acquire(3, 1, &owner) == 0, "lifecycle owner");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING, "lifecycle parent");
    check(core.association_abort(3, owner, ticket) == 0, "lifecycle fixture release");
    const auto key = std::make_pair(f.handles[f.state].file, std::wstring{L"associations.bin"});
    f.objects[key] = f.good(false); f.contents[f.objects[key].file] = {1, 2, 3};
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == 0, "lifecycle existing target");
    for (const auto& held : f.handles) if (held.second.file == f.objects[key].file) f.old_target = held.first;
    check(f.old_target != nullptr, "original target held after begin");
    // Exercise the OS restriction directly; a fake must not accept an open
    // destination, irrespective of delete sharing or ReplaceIfExists.
    const auto synthetic = f.handle(f.good(false), false);
    f.flushed = synthetic;
    check(f.replace_file(synthetic, f.state, true) == SHIROHA_NATIVE_COMMIT_UNKNOWN,
          "class 10 fake rejects an open destination");
    check(f.contents[f.objects[key].file] == std::vector<uint8_t>({1, 2, 3}), "rejected rename preserves old content");
    check(f.close(synthetic), "synthetic handle release");
    const auto renames = f.rename_calls;
    f.fail_old_target_close = fail_old_close;
    CommitDiagnostic detail;
    const auto result = core.association_commit(3, owner, ticket, input, sizeof(input), &detail);
    check(result == (fail_old_close ? SHIROHA_NATIVE_UNAVAILABLE : SHIROHA_NATIVE_OK), "old target close controls publication");
    check(f.old_target_closes == 1 && f.rename_calls == renames + (fail_old_close ? 0 : 1), "one close; no rename on uncertain close");
    check(detail.stage == (fail_old_close ? CommitStage::target_close : CommitStage::complete), "old target close diagnostic");
    check(core.association_abort(3, owner, ticket) == SHIROHA_NATIVE_INVALID_INPUT, "failed/successful commit consumes ticket");
    const auto temp = std::make_pair(key.first, std::wstring{L"~tmp-0123456789abcdef-01234567"});
    const auto closes = f.closes;
    if (fail_old_close) {
      check(f.objects.count(temp) == 1 && f.contents[f.objects[key].file] == std::vector<uint8_t>({1, 2, 3}), "close failure leaves inert temp and old target");
      check(core.close(3, owner) == SHIROHA_NATIVE_UNAVAILABLE && f.closes == closes, "quarantine never retries uncertain old handle");
    } else {
      check(f.contents[f.objects[key].file] == std::vector<uint8_t>({4, 5, 6}), "closed target permits replacement");
      check(core.close(3, owner) == 0 && f.handles.empty(), "lifecycle normal release");
    }
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
    uint8_t output[64]{}, input[]{4, 5, 6};
    check(core.acquire(3, 1, &owner) == 0, "existing drift owner");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING, "existing drift parent");
    check(core.association_abort(3, owner, ticket) == 0, "existing drift fixture release");
    const auto key = std::make_pair(f.handles[f.state].file, std::wstring{L"associations.bin"});
    f.objects[key] = f.good(false); f.contents[f.objects[key].file] = {1, 2, 3};
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == 0, "existing drift snapshot");
    const auto original = f.objects[key].file;
    f.target_changed_on_flush = true;
    CommitDiagnostic detail;
    check(core.association_commit(3, owner, ticket, input, sizeof(input), &detail) == SHIROHA_NATIVE_UNAVAILABLE,
          "existing identity drift denies before rename");
    check(f.rename_calls == 0 && detail.stage == CommitStage::prepare && f.objects[key].file != original,
          "identity check precedes target release/publication");
    check(f.objects.count({key.first, L"~tmp-0123456789abcdef-01234567"}) == 1,
          "identity denial retains inert temp");
    check(core.close(3, owner) == 0 && f.handles.empty(), "existing drift normal release");
  }
  for (const bool existing : {false, true}) {
    for (int fault = 0; fault < 6; ++fault) {
      Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
      uint8_t output[64]{}, input[]{4, 5, 6};
      check(core.acquire(3, 1, &owner) == 0, "diagnostic owner");
      check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING, "diagnostic parent");
      check(core.association_abort(3, owner, ticket) == 0, "fixture transaction released");
      const auto key = std::make_pair(f.handles[f.state].file, std::wstring{L"associations.bin"});
      if (existing) { f.objects[key] = f.good(false); f.contents[f.objects[key].file] = {1, 2, 3}; }
      check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == (existing ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_MISSING), "diagnostic snapshot");
      if (fault == 1 || fault == 5) f.fail_stage = L"replace";
      if (fault == 2) f.fail_published_close = true;
      if (fault == 3) f.corrupt_published_identity = true;
      if (fault == 4) f.throw_after_replace = true;
      if (fault == 5) f.fail_finish_after_replace = true;
      CommitDiagnostic detail;
      const auto result = core.association_commit(3, owner, ticket, input, sizeof(input), &detail);
      check(result == (fault == 0 ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_COMMIT_UNKNOWN), "uncertain publication never success");
      const auto expected = fault == 0 ? CommitStage::complete : fault == 2 ? CommitStage::published_close : fault == 3 ? CommitStage::published_validate : CommitStage::rename;
      check(detail.stage == expected && detail.exception == (fault == 4) && detail.finish_failed == (fault == 5), "internal failure boundary distinguished");
      const auto temp = std::make_pair(key.first, std::wstring{L"~tmp-0123456789abcdef-01234567"});
      if (fault == 1 || fault == 5) {
        check(f.objects.count(temp) == 1, "rename failure preserves inert temp");
        check(existing ? f.contents[f.objects[key].file] == std::vector<uint8_t>({1, 2, 3}) : !f.objects.count(key), "rename failure preserves old target/absence");
      }
      check(f.file_events.back() == (existing ? L"replace-existing" : L"replace-new") || fault == 0 || fault == 3, "exact new/existing branch");
      const auto closes = f.closes;
      const auto closed = core.close(3, owner);
      if (fault == 2 || fault == 5) check(closed == SHIROHA_NATIVE_UNAVAILABLE && f.closes == closes, "unknown close quarantined without retry");
      else check(closed == 0 && f.handles.empty(), "diagnostic handles settled");
      if (fault == 1) check(f.objects.count(temp) == 1, "owner close never cleans leftover");
    }
  }
  // Production file transaction core with synthetic handles/operations only.
  for (const bool existing : {false, true}) {
    for (const auto* stage : {L"", L"open", L"read", L"count", L"random", L"create", L"write", L"flush", L"replace"}) {
      Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 99;
      check(core.acquire(3, 1, &owner) == 0, "P20 owner acquired");
      // state identity from App acquisition, independent of any caller path.
      HANDLE state = nullptr;
      // Locate state through the fixture's object names, then its held handle.
      uint64_t state_file = 0;
      for (const auto& item : f.objects) if (item.first.second == L"state") state_file = item.second.file;
      for (const auto& item : f.handles) if (item.second.file == state_file) state = item.first;
      check(state != nullptr, "state is pinned");
      const auto key = std::make_pair(state_file, std::wstring{L"associations.bin"});
      const std::vector<uint8_t> old{1, 2, 3}, updated{4, 5, 6};
      if (existing) { f.objects[key] = f.good(false); f.contents[f.objects[key].file] = old; }
      f.fail_stage = stage;
      uint8_t output[64]{};
      const auto begin = core.association_begin(3, owner, output, sizeof(output), &written, &ticket);
      if (f.fail_stage == L"open" || (existing && f.fail_stage == L"read")) {
        check(begin == SHIROHA_NATIVE_UNAVAILABLE && ticket == 0 && written == 0, "read failure is not Missing");
      } else {
        check(begin == (existing ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_MISSING) && ticket > 0,
              "Missing/current object retained under owner");
        check(written == (existing ? old.size() : 0), "bounded ciphertext snapshot");
        uint64_t other = 77, count2 = 77;
        check(core.association_begin(3, owner, output, sizeof(output), &count2, &other) == SHIROHA_NATIVE_RESOURCE_LIMIT && other == 0,
              "second transaction cannot interleave CAS");
        const auto commit = core.association_commit(3, owner, ticket, updated.data(), updated.size());
        const bool success = f.fail_stage.empty() || (!existing && f.fail_stage == L"read");
        check(commit == (success ? SHIROHA_NATIVE_OK : f.fail_stage == L"replace" ? SHIROHA_NATIVE_COMMIT_UNKNOWN : SHIROHA_NATIVE_UNAVAILABLE),
              "write/flush/replace failures distinguished");
        if (success) check(f.contents[f.objects[key].file] == updated, "whole new object visible");
        else check(existing ? f.contents[f.objects[key].file] == old : !f.objects.count(key), "failure preserves previous target");
        check(core.association_abort(3, owner, ticket) == SHIROHA_NATIVE_INVALID_INPUT, "ticket consumed exactly once");
      }
      check(core.close(3, owner) == 0 && f.handles.empty(), "all transaction and owner handles released");
    }
  }
  for (int scenario = 0; scenario < 9; ++scenario) {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
    uint8_t output[64]{}, updated[]{4, 5, 6};
    check(core.acquire(3, 1, &owner) == 0, "negative-case App owner");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING, "negative-case Missing");
    if (scenario == 0) f.leftovers = 32;
    if (scenario == 1) f.collision = true;
    if (scenario == 2) f.temp_corrupt = true;
    if (scenario == 3) f.lock_lost_on_flush = true;
    if (scenario == 4) f.target_changed_on_flush = true;
    if (scenario == 5) f.unknown_after_replace = true;
    if (scenario == 6) f.change_identity = true;
    if (scenario == 7) { check(core.close(3, owner) == 0, "owner close aborts transaction"); }
    if (scenario == 8) f.throw_after_replace = true;
    const auto result = core.association_commit(3, owner, ticket, updated, sizeof(updated));
    check(result == (scenario == 0 ? SHIROHA_NATIVE_RESOURCE_LIMIT : (scenario == 5 || scenario == 8) ? SHIROHA_NATIVE_COMMIT_UNKNOWN : scenario == 7 ? SHIROHA_NATIVE_INVALID_INPUT : SHIROHA_NATIVE_UNAVAILABLE),
          "limits, collision, reparse, lock/target/parent loss and unknown outcome deny");
    if (scenario != 7) check(core.close(3, owner) == 0 && f.handles.empty(), "negative-case release");
  }
  {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
    uint8_t output[64]{}, input[]{1, 2, 3};
    check(core.acquire(3, 1, &owner) == 0, "P20 cleanup owner");
    const auto calls = f.calls.size();
    check(core.association_begin(2, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_ABI_MISMATCH && ticket == 0 && f.calls.size() == calls,
          "association ABI rejection before OS");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &written) == SHIROHA_NATIVE_INVALID_INPUT,
          "aliased ticket/count rejected");
    check(core.association_begin(3, owner, output, 0, &written, &ticket) == SHIROHA_NATIVE_INVALID_INPUT,
          "invalid output extent rejected");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING,
          "abort Missing retains owner");
    check(core.association_abort(3, owner, ticket) == 0 && core.validate(3, owner) == 0,
          "ordinary abort releases only transaction");
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING,
          "new transaction after abort");
    f.fail_stage = L"write"; f.fail_close = true;
    check(core.association_commit(3, owner, ticket, input, sizeof(input)) == SHIROHA_NATIVE_UNAVAILABLE,
          "close failure quarantines transaction owner");
    const auto closes = f.closes;
    check(core.close(3, owner) == SHIROHA_NATIVE_UNAVAILABLE && f.closes == closes,
          "unknown handle close never retried");
  }
  for (const size_t length : {size_t{0}, size_t{65537}}) {
    Fake f; ProtectedObjects core(f); uint64_t owner = 0, ticket = 0, written = 0;
    uint8_t output[64]{};
    check(core.acquire(3, 1, &owner) == 0, "corrupt-file owner");
    // Fixture first discovers the fixed parent under a valid Missing transaction.
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_MISSING, "locate fixed parent");
    check(core.association_abort(3, owner, ticket) == 0, "release discovery transaction");
    const auto key = std::make_pair(f.handles[f.state].file, std::wstring{L"associations.bin"});
    f.objects[key] = f.good(false); f.contents[f.objects[key].file].resize(length);
    check(core.association_begin(3, owner, output, sizeof(output), &written, &ticket) == SHIROHA_NATIVE_DATA_CORRUPT && ticket == 0 && written == 0,
          "empty/oversized existing object is corrupt, never Missing");
    check(core.close(3, owner) == 0 && f.handles.empty(), "corrupt-file resources released");
  }
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
