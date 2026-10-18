#ifndef SHIROHA_L1_TRIAL1A_DIAGNOSTIC_ENTRY_H_
#define SHIROHA_L1_TRIAL1A_DIAGNOSTIC_ENTRY_H_
#include "diagnostics/l1_trial1a_bootstrap.h"

// Diagnostic C++ packet ABI only: caller and entry MUST use the same reviewed
// compiler/CRT/headers. Not part of the production Native FFI ABI. The reviewed
// launcher supplies its exact private packet AFTER independent artifact build,
// including its own image pin/hash; no self-embedded EXE digest is required.
// Loading this DLL grants nothing. Calling requires separate launch authority.
// The output borrows process-lifetime custody; never delete it. UNKNOWN retains
// the owning composition, its pins and ledger for the approved manual handoff.
// No CLI, environment, JSON, ordinary configuration or DllMain activation.
extern "C" int shiroha_trial1a_entry(
    const shiroha_l1_crypto::trial1a::Invocation *fixed_packet,
    const shiroha_l1_crypto::trial1a::InvocationResult **result) noexcept;
#endif
