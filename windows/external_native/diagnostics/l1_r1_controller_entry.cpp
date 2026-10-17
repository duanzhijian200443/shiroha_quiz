#include "diagnostics/l1_r1_wiring.h"

int wmain(int argc, wchar_t **argv) {
  shiroha_l1_crypto::r1::ClosedWindowsBoundary boundary;
  return shiroha_l1_crypto::r1::controller_process_entry(argc, argv, boundary);
}
