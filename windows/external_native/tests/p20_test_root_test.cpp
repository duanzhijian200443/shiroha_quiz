#include "diagnostics/p20_test_root.h"
#include <cstdlib>
#include <iostream>

namespace {
int calls = 0;
int32_t fake_production(std::wstring& value) {
  ++calls;
  value = L"C:\\fake-known-folder";
  return SHIROHA_NATIVE_OK;
}
void check(bool value) { if (!value) std::exit(1); }
}
int main() {
  std::wstring path = L"stale";
  check(shiroha_native::resolve_object_root(path, fake_production) == SHIROHA_NATIVE_OK);
#if defined(SHIROHA_P20_DIAGNOSTIC_BUILD)
  check(calls == 0 && path == shiroha_p20_test_root);
  std::cout << "PASS: diagnostic compiled absolute root, zero production resolver calls\n";
#else
  check(calls == 1 && path == L"C:\\fake-known-folder");
  std::cout << "PASS: production calls only its default resolver, no diagnostic root\n";
#endif
  std::wstring native;
  for (const auto* invalid : {L"", L"relative", L"C:relative", L"\\rooted", L"\\\\server\\share", L"C:\\a\\..\\b", L"C:\\a\\.\\b", L"C:\\a:b"}) {
    check(!shiroha_native::local_nt_name(invalid, native));
  }
  return 0;
}
