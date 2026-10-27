#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <tlhelp32.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// Presentation only. No credential, trust or process-custody decision uses
// these window observations; Dart/Native still perform the original admission.
void PlacePairingBesideParent(HWND child) {
  DWORD parent_id = 0;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == GetCurrentProcessId()) {
        parent_id = entry.th32ParentProcessID;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  if (!parent_id) return;
  HANDLE parent = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, parent_id);
  if (!parent) return;
  wchar_t current_path[32768]{}, parent_path[32768]{};
  DWORD length = 32768;
  const bool same_image =
      GetModuleFileNameW(nullptr, current_path, 32768) != 0 &&
      QueryFullProcessImageNameW(parent, 0, parent_path, &length) &&
      _wcsicmp(current_path, parent_path) == 0;
  CloseHandle(parent);
  if (!same_image) return;
  struct WindowSearch { DWORD pid; HWND window; } search{parent_id, nullptr};
  EnumWindows([](HWND window, LPARAM value) -> BOOL {
    auto* search = reinterpret_cast<WindowSearch*>(value);
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == search->pid && IsWindowVisible(window) &&
        GetWindow(window, GW_OWNER) == nullptr) {
      search->window = window;
      return FALSE;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&search));
  if (!search.window) return;
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromWindow(search.window, MONITOR_DEFAULTTONEAREST),
                       &monitor)) return;
  const RECT area = monitor.rcWork;
  const int width = area.right - area.left, height = area.bottom - area.top;
  if (width < 1000 || height < 500) return;
  // Keep the App's size and focus. Existing-credential proof needs a decision
  // only in that App; this independent child must not pull the user away.
  SetWindowPos(child, nullptr, area.left + width / 2, area.top,
               width - width / 2, height, SWP_NOZORDER | SWP_NOACTIVATE);
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool pairing_window = command_line_arguments.size() == 1 &&
      command_line_arguments[0] == "--shiroha-bridge-pairing-ui";

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, !pairing_window);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Shiroha Quiz", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (pairing_window) PlacePairingBesideParent(window.GetHandle());

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Framework-requested exit posts WM_QUIT without first destroying the HWND.
  // Clear the controller through the live derived OnDestroy before its member
  // destructor can re-enter window dispatch with a partially destroyed view.
  window.Destroy();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
