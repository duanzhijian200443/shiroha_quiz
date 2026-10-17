#include "diagnostics/l1_r2_adapters.h"
int wmain(int argc, wchar_t **argv) {
  return shiroha_l1_crypto::r2::custodian_process_entry(argc, argv);
}
