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
  virtual int32_t credential_open(HANDLE, uint32_t, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t credential_replace(HANDLE, HANDLE, uint32_t, bool) { return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
  virtual int32_t read_file(HANDLE, std::vector<uint8_t>&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t temporary_count(HANDLE, size_t&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t random_name(std::wstring&, std::wstring&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t temporary_create(HANDLE, const std::wstring&, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t write_file(HANDLE, const uint8_t*, uint64_t) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t flush_file(HANDLE) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t replace_file(HANDLE, HANDLE, bool) { return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
  // P24: short-lived Exchange-only cross-process exclusion, not a store ticket.
  virtual int32_t exchange_lock(const ObjectInfo&, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual bool exchange_unlock(HANDLE) noexcept { return false; }
  virtual int32_t exchange_count(HANDLE, size_t&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  // mode: 0=create-new, 1=read, 2=identity pin, 3=creator deletion,
  // 4=consumer read+delete (same protected handle, denies write/delete sharing).
  virtual int32_t exchange_open(HANDLE, const std::wstring&, uint32_t, const Sid&, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t exchange_nonce(uint8_t*, size_t) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t exchange_read(HANDLE, size_t, std::vector<uint8_t>&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t exchange_delete(HANDLE) { return SHIROHA_NATIVE_UNAVAILABLE; }
  // P26 fixed Discovery objects; no arbitrary name/path or deletion capability.
  virtual int32_t discovery_open(HANDLE, uint32_t, HANDLE&) { return SHIROHA_NATIVE_UNAVAILABLE; }
  virtual int32_t discovery_replace(HANDLE, HANDLE, uint32_t, bool) { return SHIROHA_NATIVE_COMMIT_UNKNOWN; }
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
  enum class OpenMode { initialize, existing_only };
  static constexpr size_t max_owners = 32;
  explicit ProtectedObjects(ObjectOperations& ops,
      OpenMode mode = OpenMode::initialize) noexcept : ops_(ops), mode_(mode) {}
  ~ProtectedObjects() noexcept;
  int32_t acquire(uint32_t version, uint32_t role, uint64_t* token) noexcept;
  int32_t validate(uint32_t version, uint64_t token) noexcept;
  int32_t close(uint32_t version, uint64_t token) noexcept;
  int32_t association_begin(uint32_t, uint64_t, uint8_t*, uint64_t, uint64_t*, uint64_t*) noexcept;
  int32_t association_commit(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t,
                             CommitDiagnostic* = nullptr) noexcept;
  int32_t association_abort(uint32_t, uint64_t, uint64_t) noexcept;
  int32_t credential_begin(uint32_t, uint64_t, uint32_t, uint8_t*, uint64_t, uint64_t*, uint64_t*) noexcept;
  int32_t credential_commit(uint32_t, uint64_t, uint64_t, const uint8_t*, uint64_t) noexcept;
  int32_t credential_abort(uint32_t, uint64_t, uint64_t) noexcept;
  int32_t exchange_create(uint32_t, uint64_t, uint32_t, const uint8_t*, const uint8_t*, uint64_t, uint64_t*) noexcept;
  int32_t exchange_read(uint32_t, uint64_t, uint32_t, const uint8_t*, uint8_t*, uint64_t, uint64_t*) noexcept;
  int32_t exchange_cleanup(uint32_t, uint64_t, uint64_t) noexcept;
  int32_t exchange_read_begin(uint32_t, uint64_t, uint32_t, const uint8_t*, uint8_t*, uint64_t, uint64_t*, uint8_t*) noexcept;
  int32_t exchange_consume(uint32_t, uint64_t, const uint8_t*) noexcept;
  int32_t exchange_release(uint32_t, uint64_t, const uint8_t*) noexcept;
  int32_t discovery_read(uint32_t, uint64_t, uint32_t, uint8_t*, uint64_t, uint64_t*) noexcept;
  int32_t discovery_publish(uint32_t, uint64_t, uint32_t, const uint8_t*, uint64_t) noexcept;
 private:
  int32_t begin(uint32_t, uint64_t, uint32_t, uint8_t*, uint64_t, uint64_t*, uint64_t*) noexcept;
  int32_t commit(uint32_t, uint64_t, uint64_t, bool, const uint8_t*, uint64_t, CommitDiagnostic*) noexcept;
  int32_t abort(uint32_t, uint64_t, uint64_t, bool) noexcept;
  struct Pin { HANDLE handle = nullptr; ObjectInfo identity; bool owner, dacl; };
  struct ExchangeReceipt {
    uint64_t token = 0;
    HANDLE pin = nullptr;
    ObjectInfo identity;
    std::wstring name;
  };
  struct ExchangeRead : ExchangeReceipt {
    std::array<uint8_t, 16> nonce{};
    std::vector<uint8_t> bytes;
    uint32_t kind = 0;
  };
  struct Lease {
    uint64_t token = 0;
    std::vector<Pin> pins;
    bool denied = false, quarantined = false;
    uint32_t role = 0;
    uint32_t kind = 3;
    uint64_t ticket = 0;
    HANDLE target = nullptr, temporary = nullptr;
    ObjectInfo target_identity;
    bool missing = false;
    std::wstring runtime_id;
    Pin exchange{}; // Separate from the unchanged P19/P20/P23 pin layout.
    Pin discovery{};
    std::array<ExchangeReceipt, 32> exchange_receipts{};
    std::array<ExchangeRead, 32> exchange_reads{};
  };
  int32_t add(Lease& lease, HANDLE parent, const wchar_t* name,
              bool directory, const Sid& sid, bool dacl, bool create = true);
  int32_t inspect_pins(Lease& lease, const Sid& sid);
  bool release(Lease& lease) noexcept;
  Lease* find(uint64_t token) noexcept;
  static size_t directory(const Lease& lease) noexcept { return lease.kind == 3 ? 6u : lease.kind == 4 ? 3u : 5u; }
  int32_t open_target(Lease&, const Sid&, HANDLE&);
  int32_t check(Lease&, Sid&);
  int32_t target_current(Lease&, const Sid&);
  bool finish(Lease&) noexcept;
  int32_t exchange_directory(Lease&, Sid&);
  int32_t discovery_directory(Lease&, Sid&);
  int32_t discovery_operation(uint64_t, uint32_t, const uint8_t*, uint64_t, uint8_t*, uint64_t, uint64_t*, bool);
  int32_t exchange_operation(uint64_t, uint32_t, const uint8_t*, const uint8_t*, uint64_t,
      uint8_t*, uint64_t, uint64_t*, uint64_t*, bool, uint8_t* = nullptr);
  int32_t exchange_settle(uint32_t, uint64_t, const uint8_t*, bool) noexcept;
  ObjectOperations& ops_;
  const OpenMode mode_;
  std::mutex mutex_;
  uint64_t next_token_ = 1; // Never reused, including failed acquisitions.
  uint64_t next_ticket_ = 1;
  std::array<std::unique_ptr<Lease>, max_owners> owners_{};
};
}  // namespace shiroha_native
#endif
