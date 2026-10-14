#ifndef SHIROHA_P20_TEST_ROOT_H_
#define SHIROHA_P20_TEST_ROOT_H_
#include "protected_objects.h"
#if defined(SHIROHA_P20_DIAGNOSTIC_BUILD)
#include "p20_test_root_config.h"
#endif

namespace shiroha_native {
// Internal source seam. Production cannot see/read a diagnostic root value.
inline int32_t resolve_object_root(std::wstring& path,
                                  int32_t (*production_root)(std::wstring&)) {
  path.clear();
#if defined(SHIROHA_P20_DIAGNOSTIC_BUILD)
  (void)production_root;
  std::wstring nt_name;
  if (!local_nt_name(shiroha_p20_test_root, nt_name)) return SHIROHA_NATIVE_INVALID_INPUT;
  path = shiroha_p20_test_root;
  return SHIROHA_NATIVE_OK;
#else
  return production_root(path);
#endif
}
}  // namespace shiroha_native
#endif
