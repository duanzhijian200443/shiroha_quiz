#include "diagnostics/l1_trial1a_diagnostic_entry.h"
#include "diagnostics/l1_trial1a_real_windows.h"
namespace t = shiroha_l1_crypto::trial1a;
namespace {
t::ProcessLatch process;
}
extern "C" __declspec(dllexport) int
shiroha_trial1a_entry(const t::Invocation *fixed_packet,
                      const t::InvocationResult **result) noexcept {
  return int(process.start<t::WindowsRealEntry>(fixed_packet, result));
}
