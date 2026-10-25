// Local peer/pipe custody only. No External store, DPAPI, Discovery or TLS.
#include <windows.h>
#include <sddl.h>
#include <bcrypt.h>
#include <tlhelp32.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cwctype>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {
constexpr int ok = 0, pending = 1, disconnected = 2, rejected = 3;
constexpr DWORD capacity = 65536;
std::atomic<bool> cleanup_failed{false};
constexpr DWORD pipe_access = FILE_READ_DATA | FILE_WRITE_DATA |
    FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  Handle() = default;
  explicit Handle(HANDLE h) : value(h) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  ~Handle() { if (valid() && !CloseHandle(value)) cleanup_failed = true; }
  bool valid() const { return value && value != INVALID_HANDLE_VALUE; }
  bool close() {
    if (!valid()) return true;
    if (!CloseHandle(value)) { cleanup_failed = true; return false; }
    value = INVALID_HANDLE_VALUE;
    return true;
  }
};
std::wstring image(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD count = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &count) || count == 0)
    return {};
  path.resize(count);
  return path;
}
std::vector<uint8_t> user_sid(HANDLE process) {
  Handle token;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return {};
  TOKEN_ELEVATION elevation{};
  DWORD elevation_size = 0;
  if (!GetTokenInformation(token.value, TokenElevation, &elevation,
                          sizeof(elevation), &elevation_size) ||
      elevation.TokenIsElevated) return {};
  DWORD count = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &count);
  if (count == 0 || count > 65536) return {};
  std::vector<uint8_t> user(count);
  if (!GetTokenInformation(token.value, TokenUser, user.data(), count, &count))
    return {};
  const PSID sid = reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid;
  if (!IsValidSid(sid)) return {};
  std::vector<uint8_t> result(GetLengthSid(sid));
  if (!CopySid(static_cast<DWORD>(result.size()), result.data(), sid)) return {};
  return result;
}
bool bind_image(HANDLE process, const std::wstring& expected,
                Handle& expected_file, Handle& actual_file) {
  const auto actual = image(process);
  if (actual.empty()) return false;
  expected_file.value = CreateFileW(expected.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  actual_file.value = CreateFileW(actual.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  BY_HANDLE_FILE_INFORMATION left{}, right{};
  return expected_file.valid() && actual_file.valid() &&
      GetFileInformationByHandle(expected_file.value, &left) &&
      GetFileInformationByHandle(actual_file.value, &right) &&
      !((left.dwFileAttributes | right.dwFileAttributes) &
          (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
      left.dwVolumeSerialNumber == right.dwVolumeSerialNumber &&
      left.nFileIndexHigh == right.nFileIndexHigh &&
      left.nFileIndexLow == right.nFileIndexLow;
}
DWORD parent_id() {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (!snapshot.valid()) return 0;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  DWORD result = 0;
  if (Process32FirstW(snapshot.value, &entry)) {
    size_t remaining = 65536;
    do {
      if (entry.th32ProcessID == GetCurrentProcessId()) {
        result = entry.th32ParentProcessID;
        break;
      }
    } while (--remaining && Process32NextW(snapshot.value, &entry));
  }
  return snapshot.close() ? result : 0;
}
std::wstring sid_text(const std::vector<uint8_t>& sid) {
  if (sid.empty()) return {};
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(const_cast<uint8_t*>(sid.data()), &text)) return {};
  const std::wstring result(text);
  LocalFree(text);
  return result;
}
std::wstring endpoint(const std::wstring& root, const std::wstring& sid,
                      DWORD session) {
  std::wstring material = root + L"|" + sid + L"|" + std::to_wstring(session);
  std::transform(material.begin(), material.end(), material.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0) return {};
  uint8_t digest[32]{};
  const bool valid = BCryptCreateHash(algorithm, &hash, nullptr, 0,
                                     nullptr, 0, 0) >= 0 &&
      BCryptHashData(hash, reinterpret_cast<PUCHAR>(material.data()),
          static_cast<ULONG>(material.size() * sizeof(wchar_t)), 0) >= 0 &&
      BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!valid) return {};
  std::wstring result = L"\\\\.\\pipe\\ShirohaCodexRelayV1_";
  constexpr wchar_t hex[] = L"0123456789abcdef";
  for (const auto byte : digest) {
    result.push_back(hex[byte >> 4]);
    result.push_back(hex[byte & 15]);
  }
  return result;
}
struct Pipe {
  bool server = false, connected = false, failed = false;
  DWORD session = 0;
  std::wstring root;
  std::vector<uint8_t> sid;
  Handle pipe, peer, expected_image, actual_image;
  Handle launch_parent, expected_shell, actual_shell;
  bool independent_launch() {
    // Any-Job membership does not identify a Codex-owned Job. This mode admits
    // only a normal direct Explorer launch, using kernel process/file facts.
    // It does not grant business authority or resist same-user process spoofing.
    const DWORD parent = parent_id();
    DWORD shell = 0;
    const HWND shell_window = GetShellWindow();
    if (!shell_window || !GetWindowThreadProcessId(shell_window, &shell) ||
        !parent || parent != shell || parent == GetCurrentProcessId())
      return false;  // An agent-started explorer.exe is not the desktop shell.
    launch_parent.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                                      FALSE, parent);
    if (!launch_parent.valid()) return false;
    const auto parent_sid = user_sid(launch_parent.value);
    DWORD parent_session = 0;
    if (parent_sid.empty() ||
        !EqualSid(sid.data(), const_cast<uint8_t*>(parent_sid.data())) ||
        !ProcessIdToSessionId(parent, &parent_session) || parent_session != session)
      return false;
    FILETIME parent_created{}, self_created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(launch_parent.value, &parent_created, &exited, &kernel, &user) ||
        !GetProcessTimes(GetCurrentProcess(), &self_created, &exited, &kernel, &user) ||
        CompareFileTime(&parent_created, &self_created) >= 0)
      return false;  // Refuse a reused parent PID.
    std::wstring system_root(32768, L'\0');
    const UINT count = GetSystemWindowsDirectoryW(system_root.data(),
                                                  static_cast<UINT>(system_root.size()));
    if (!count || count >= system_root.size()) return false;
    system_root.resize(count);
    return bind_image(launch_parent.value, system_root + L"\\explorer.exe",
                      expected_shell, actual_shell) && launch_current();
  }
  bool launch_current() const {
    return !server || (launch_parent.valid() &&
        WaitForSingleObject(launch_parent.value, 0) == WAIT_TIMEOUT);
  }
  bool authenticate() {
    ULONG id = 0;
    if (!(server ? GetNamedPipeClientProcessId(pipe.value, &id)
                 : GetNamedPipeServerProcessId(pipe.value, &id)) || id == 0)
      return false;
    peer.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                             FALSE, id);
    DWORD peer_session = 0;
    const auto other_sid = peer.valid() ? user_sid(peer.value)
                                         : std::vector<uint8_t>{};
    if (!peer.valid() || other_sid.empty() ||
        !EqualSid(sid.data(), const_cast<uint8_t*>(other_sid.data())) ||
        !ProcessIdToSessionId(id, &peer_session) || peer_session != session)
      return false;
    const auto expected = root + (server ? L"\\shiroha_codex.exe"
                                         : L"\\shiroha_quiz.exe");
    return bind_image(peer.value, expected, expected_image, actual_image) &&
        WaitForSingleObject(peer.value, 0) == WAIT_TIMEOUT && launch_current();
  }
  bool live() const {
    return connected && !failed && peer.valid() &&
        WaitForSingleObject(peer.value, 0) == WAIT_TIMEOUT && launch_current();
  }
  bool close() {
    failed = true;
    // Nonblocking pipe operations: no outstanding OVERLAPPED/buffer custody.
    bool success = pipe.close();
    success = peer.close() && success;
    success = actual_image.close() && success;
    success = expected_image.close() && success;
    success = launch_parent.close() && success;
    success = actual_shell.close() && success;
    success = expected_shell.close() && success;
    return success;
  }
};
std::mutex mutex;
std::unique_ptr<Pipe> owned;
uint64_t generation = 0;
Pipe* get(uint64_t id) { return owned && generation == id ? owned.get() : nullptr; }
}

#define API extern "C" __declspec(dllexport)
API uint32_t shiroha_relay_version() { return 1; }
API uint32_t shiroha_relay_healthy() { return cleanup_failed ? 0u : 1u; }
API void* shiroha_relay_allocate(uint32_t count) {
  return count > 0 && count <= capacity ? HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, count) : nullptr;
}
API void shiroha_relay_free(void* buffer) {
  if (buffer && !HeapFree(GetProcessHeap(), 0, buffer)) cleanup_failed = true;
}
static int open_pipe(uint32_t role, uint64_t* output) {
  if (!output || role > 1) return rejected;
  *output = 0;
  std::lock_guard<std::mutex> guard(mutex);
  if (owned || cleanup_failed || generation == UINT64_MAX) return rejected;
  auto p = std::make_unique<Pipe>();
  p->server = role == 0;
  const auto self = image(GetCurrentProcess());
  const auto split = self.find_last_of(L"\\/");
  if (split == std::wstring::npos) return rejected;
  const auto name = self.substr(split + 1);
  if (_wcsicmp(name.c_str(), p->server ? L"shiroha_quiz.exe"
                                      : L"shiroha_codex.exe") != 0)
    return rejected;
  p->root = self.substr(0, split);
  p->sid = user_sid(GetCurrentProcess());
  if (p->sid.empty() || !ProcessIdToSessionId(GetCurrentProcessId(), &p->session))
    return rejected;
  const auto sid = sid_text(p->sid);
  const auto address = endpoint(p->root, sid, p->session);
  if (sid.empty() || address.empty()) return rejected;
  if (p->server) {
    if (!p->independent_launch()) return 6;
    const auto sddl = L"O:" + sid + L"D:P(A;;0x00120183;;;" + sid + L")";
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),
            SDDL_REVISION_1, &descriptor, nullptr)) return rejected;
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    p->pipe.value = CreateNamedPipeW(address.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, capacity, capacity, 0, &attributes);
    LocalFree(descriptor);
  } else {
    p->pipe.value = CreateFileW(address.c_str(), pipe_access, 0, nullptr,
        OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
    if (!p->pipe.valid() || !SetNamedPipeHandleState(p->pipe.value, &mode, nullptr, nullptr) ||
        !p->authenticate()) return rejected;
    p->connected = true;
  }
  if (!p->pipe.valid()) return rejected;
  owned = std::move(p);
  *output = ++generation;
  return ok;
}
API int shiroha_relay_open(uint32_t role, uint64_t* output) {
  try { return open_pipe(role, output); } catch (...) { return rejected; }
}
static int accept_pipe(uint64_t id) {
  std::lock_guard<std::mutex> guard(mutex);
  auto* p = get(id);
  if (!p || !p->server || p->failed || !p->launch_current()) return rejected;
  if (p->connected) return p->live() ? ok : disconnected;
  const BOOL connected = ConnectNamedPipe(p->pipe.value, nullptr);
  const DWORD error = connected ? ERROR_SUCCESS : GetLastError();
  if (error == ERROR_PIPE_LISTENING) return pending;
  if (error != ERROR_SUCCESS && error != ERROR_PIPE_CONNECTED) {
    p->failed = true;
    return rejected;
  }
  // The first nonblocking connect can merely make the instance available.
  // Do not authenticate until a client actually connected.
  if (!PeekNamedPipe(p->pipe.value, nullptr, 0, nullptr, nullptr, nullptr)) {
    const auto status = GetLastError();
    if (status == ERROR_PIPE_LISTENING || status == ERROR_PIPE_NOT_CONNECTED ||
        status == ERROR_BAD_PIPE) return pending;
    p->failed = true;
    return rejected;
  }
  if (!p->authenticate()) { p->failed = true; return rejected; }
  p->connected = true;
  return ok;
}
API int shiroha_relay_accept(uint64_t id) {
  try { return accept_pipe(id); } catch (...) { return rejected; }
}
API int shiroha_relay_read(uint64_t id, uint8_t* data, uint32_t size, uint32_t* count) {
  if (!data || !count || size == 0 || size > capacity) return rejected;
  *count = 0;
  std::lock_guard<std::mutex> guard(mutex);
  auto* p = get(id);
  if (!p || !p->live()) return disconnected;
  DWORD available = 0;
  if (!PeekNamedPipe(p->pipe.value, nullptr, 0, nullptr, &available, nullptr))
    return disconnected;
  if (!available) return pending;
  DWORD bytes = 0;
  if (!ReadFile(p->pipe.value, data, std::min<DWORD>(size, available), &bytes, nullptr))
    return disconnected;
  *count = bytes;
  return bytes ? ok : pending;
}
API int shiroha_relay_write(uint64_t id, const uint8_t* data, uint32_t size, uint32_t* count) {
  if (!data || !count || size == 0 || size > capacity) return rejected;
  *count = 0;
  std::lock_guard<std::mutex> guard(mutex);
  auto* p = get(id);
  if (!p || !p->live()) return disconnected;
  DWORD bytes = 0;
  if (!WriteFile(p->pipe.value, data, size, &bytes, nullptr)) return disconnected;
  *count = bytes;
  return bytes ? ok : pending;
}
API int shiroha_relay_state(uint64_t id) {
  std::lock_guard<std::mutex> guard(mutex);
  auto* p = get(id);
  if (!p || !p->live()) return disconnected;
  return PeekNamedPipe(p->pipe.value, nullptr, 0, nullptr, nullptr, nullptr)
      ? ok : disconnected;
}
API int shiroha_relay_close(uint64_t id) {
  std::lock_guard<std::mutex> guard(mutex);
  auto* p = get(id);
  if (!p || !p->close()) return rejected;
  owned.reset();
  return ok;
}
