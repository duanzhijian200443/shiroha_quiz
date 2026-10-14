#ifndef SHIROHA_PROTECTED_OBJECTS_H_
#define SHIROHA_PROTECTED_OBJECTS_H_

#include <windows.h>
#include <array>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "shiroha_external_native.h"

namespace shiroha_native {
using Sid = std::vector<uint8_t>;
struct Ace {
  uint8_t type = 0, flags = 0;
  uint32_t mask = 0;
  Sid sid;
};
struct ObjectInfo {
  uint64_t volume = 0, file = 0;
  uint32_t attributes = 0, drive_type = 0, links = 0;
  std::wstring filesystem;
  Sid owner;
  bool dacl_present = false, dacl_protected = false;
  std::vector<Ace> aces;
};

// Internal Win32 seam: tests supply synthetic observations/handles, while the
// production core below owns all policy, ordering, identities and lifetime.
struct ObjectOperations {
  virtual ~ObjectOperations() = default;
  virtual int32_t user_sid(Sid& sid) = 0;
  virtual int32_t local_directory(HANDLE& result) = 0;
  virtual int32_t child(HANDLE parent, const wchar_t* component, bool directory,
                        bool create, const Sid& sid, HANDLE& result) = 0;
  virtual int32_t inspect(HANDLE handle, ObjectInfo& result) = 0;
  virtual bool close(HANDLE handle) noexcept = 0;
  // P20 fixed file seam. Defaults deny so P19-only fakes remain inert.
  virtual int32_t association_open(HANDLE, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t read_file(HANDLE, std::vector<uint8_t>&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t temporary_count(HANDLE, size_t&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t random_name(std::wstring&, std::wstring&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t temporary_create(HANDLE, const std::wstring&, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t write_file(HANDLE, const uint8_t*, uint64_t) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t flush_file(HANDLE) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t replace_file(HANDLE, HANDLE, bool) { return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
};

bool safe_component(const std::wstring& name) noexcept;
bool local_nt_name(const std::wstring& path, std::wstring& result);
bool object_valid(const ObjectInfo& info, const Sid& sid, bool directory,
                  bool check_owner, bool check_dacl) noexcept;

// Internal, caller-owned diagnostic output. No OS codes, paths or C ABI export.
// The stage identifies where failure occurred, not whether publication happened.
enum class CommitStage { admission, prepare, target_close, rename, published_close, published_validate, complete };
struct CommitDiagnostic {
  CommitStage stage = CommitStage::admission;
  bool exception = false;
  bool finish_failed = false;
};

class ProtectedObjects final {
 public:
  static constexpr size_t max_owners = 32;
  explicit ProtectedObjects(ObjectOperations& ops) noexcept : ops_(ops) {}
  ~ProtectedObjects() noexcept;
  int32_t acquire(uint32_t version, uint32_t role, uint64_t* token) noexcept;
  int32_t validate(uint32_t version, uint64_t token) noexcept;
  int32_t close(uint32_t version, uint64_t token) noexcept;
  int32_t association_begin(uint32_t, uint64_t, uint8_t*, uint64_t, uint64_t*, uint64_t*) noexcept;
  int32_t association_commit(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t,
                             CommitDiagnostic* = nullptr) noexcept;
  int32_t association_abort(uint32_t, uint64_t, uint64_t) noexcept;
 private:
  struct Pin { HANDLE handle = nullptr; ObjectInfo identity; bool owner, dacl; };
  struct Lease {
    uint64_t token = 0;
    std::vector<Pin> pins;
    bool denied = false, quarantined = false;
    uint32_t role = 0;
    uint64_t ticket = 0;
    HANDLE target = nullptr, temporary = nullptr;
    ObjectInfo target_identity;
    bool missing = false;
    std::wstring runtime_id;
  };
  int32_t add(Lease& lease, HANDLE parent, const wchar_t* name,
              bool directory, const Sid& sid, bool dacl, bool create = true);
  int32_t inspect_pins(Lease& lease, const Sid& sid);
  bool release(Lease& lease) noexcept;
  Lease* find(uint64_t token) noexcept;
  int32_t check(Lease&, Sid&);
  int32_t target_current(Lease&, const Sid&);
  bool finish(Lease&) noexcept;
  ObjectOperations& ops_;
  std::mutex mutex_;
  uint64_t next_token_ = 1; // Never reused, including failed acquisitions.
  uint64_t next_ticket_ = 1;
  std::array<std::unique_ptr<Lease>, max_owners> owners_{};
};
}  // namespace shiroha_native
#endif
