cmake_minimum_required(VERSION 3.14)
project(shiroha_external_native LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR
   NOT CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "x64")
  message(FATAL_ERROR "External Native Helper requires Windows x64")
endif()

# Opt-in diagnostic executable only. Production target never receives the
# definition, generated header include directory, or root value.
function(shiroha_native_settings target)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN SHIROHA_EXTERNAL_NATIVE_BUILD)
  target_compile_options(${target} PRIVATE /W4 /WX /EHsc /GS)
  target_link_options(${target} PRIVATE /DYNAMICBASE /NXCOMPAT /GUARD:CF)
  target_compile_options(${target} PRIVATE /guard:cf)
endfunction()

option(SHIROHA_P20_MINIMAL_TEST_BUILD "Compile the isolated P20 real-test candidate (never run in CTest)" OFF)
set(SHIROHA_P20_TEST_ROOT "" CACHE STRING "Explicit absolute empty ancestor for diagnostic P20 only")
if(SHIROHA_P20_MINIMAL_TEST_BUILD)
  if(NOT SHIROHA_P20_TEST_ROOT MATCHES "^[A-Za-z]:[/\\\\]" OR
     SHIROHA_P20_TEST_ROOT MATCHES "[\";\r\n]" OR
     SHIROHA_P20_TEST_ROOT MATCHES "(^|[/\\\\])\\.\\.?([/\\\\]|$)")
    message(FATAL_ERROR "P20 diagnostic test root must be an explicit absolute local path without dot segments")
  endif()
  string(REPLACE "/" "\\" SHIROHA_P20_TEST_ROOT_NATIVE "${SHIROHA_P20_TEST_ROOT}")
  configure_file(diagnostics/p20_test_root_config.h.in
    "${CMAKE_CURRENT_BINARY_DIR}/p20/p20_test_root_config.h" @ONLY)
  add_executable(shiroha_p20_minimal_test diagnostics/p20_minimal_test.cpp
    native_core.cpp native_windows.cpp protected_objects.cpp association_files.cpp exchange_files.cpp discovery_files.cpp protected_windows.cpp)
  shiroha_native_settings(shiroha_p20_minimal_test)
  target_compile_definitions(shiroha_p20_minimal_test PRIVATE SHIROHA_P20_DIAGNOSTIC_BUILD)
  target_include_directories(shiroha_p20_minimal_test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/p20")
  target_link_libraries(shiroha_p20_minimal_test PRIVATE crypt32 shell32 ole32 uuid advapi32 bcrypt)
  if(SHIROHA_NATIVE_OFFLINE_TESTS)
    foreach(kind production diagnostic)
      add_executable(shiroha_p20_root_${kind}_test tests/p20_test_root_test.cpp
        protected_objects.cpp association_files.cpp)
      shiroha_native_settings(shiroha_p20_root_${kind}_test)
      target_include_directories(shiroha_p20_root_${kind}_test PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/p20")
      if(kind STREQUAL "diagnostic")
        target_compile_definitions(shiroha_p20_root_${kind}_test PRIVATE SHIROHA_P20_DIAGNOSTIC_BUILD)
      endif()
      add_test(NAME shiroha_p20_root_${kind}_offline COMMAND shiroha_p20_root_${kind}_test)
    endforeach()
  endif()
endif()

add_library(shiroha_external_native SHARED native_core.cpp native_windows.cpp
  protected_objects.cpp association_files.cpp exchange_files.cpp discovery_files.cpp protected_windows.cpp
  native_crypto.cpp p256_key_codec.cpp crypto_windows.cpp peer_policy.cpp peer_policy_windows.cpp)
shiroha_native_settings(shiroha_external_native)
target_link_libraries(shiroha_external_native PRIVATE crypt32 shell32 ole32 uuid advapi32 bcrypt)

# Compile-only diagnostic variant. This is never a production replacement or a
# runnable Batch 3 grant; the runtime identity bridge remains separately gated.
option(SHIROHA_BATCH3_EXISTING_ONLY_BUILD "Compile Batch 3 no-initialization DLL" OFF)
if(SHIROHA_BATCH3_EXISTING_ONLY_BUILD)
  add_library(shiroha_batch3_existing_only SHARED native_core.cpp native_windows.cpp
    protected_objects.cpp association_files.cpp exchange_files.cpp discovery_files.cpp protected_windows.cpp
    native_crypto.cpp p256_key_codec.cpp crypto_windows.cpp peer_policy.cpp peer_policy_windows.cpp)
  shiroha_native_settings(shiroha_batch3_existing_only)
  target_compile_definitions(shiroha_batch3_existing_only PRIVATE SHIROHA_BATCH3_EXISTING_ONLY)
  target_link_libraries(shiroha_batch3_existing_only PRIVATE crypt32 shell32 ole32 uuid advapi32 bcrypt)
endif()

# Explicit opt-in; this executable contains core + fake Win32 operations only.
# It neither links/loads the production DLL nor calls DPAPI/known-folder APIs.
option(SHIROHA_NATIVE_OFFLINE_TESTS "Build offline core contract tests" OFF)
if(SHIROHA_NATIVE_OFFLINE_TESTS)
  enable_testing()
  add_executable(shiroha_native_offline_test native_core.cpp tests/native_core_test.cpp)
  shiroha_native_settings(shiroha_native_offline_test)
  target_include_directories(shiroha_native_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_native_offline COMMAND shiroha_native_offline_test)
  add_executable(shiroha_objects_offline_test protected_objects.cpp association_files.cpp tests/protected_objects_test.cpp)
  shiroha_native_settings(shiroha_objects_offline_test)
  target_include_directories(shiroha_objects_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_objects_offline COMMAND shiroha_objects_offline_test)
  add_executable(shiroha_exchange_offline_test protected_objects.cpp association_files.cpp
    exchange_files.cpp tests/exchange_files_test.cpp)
  shiroha_native_settings(shiroha_exchange_offline_test)
  target_include_directories(shiroha_exchange_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_exchange_offline COMMAND shiroha_exchange_offline_test)
  add_executable(shiroha_probe_offline_test tests/probe_stop_test.cpp)
  shiroha_native_settings(shiroha_probe_offline_test)
  target_include_directories(shiroha_probe_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_probe_offline COMMAND shiroha_probe_offline_test)
  add_executable(shiroha_rename_layout_test tests/rename_layout_test.cpp)
  shiroha_native_settings(shiroha_rename_layout_test)
  add_test(NAME shiroha_rename_layout_offline COMMAND shiroha_rename_layout_test)
  # P21: ECDSA P-256 core + fake operations only. This executable never links
  # bcrypt and never calls a real CNG or certificate API.
  add_executable(shiroha_crypto_offline_test native_crypto.cpp p256_key_codec.cpp tests/native_crypto_test.cpp)
  shiroha_native_settings(shiroha_crypto_offline_test)
  target_include_directories(shiroha_crypto_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_crypto_offline COMMAND shiroha_crypto_offline_test)
  add_executable(shiroha_peer_policy_offline_test peer_policy.cpp tests/peer_policy_test.cpp)
  shiroha_native_settings(shiroha_peer_policy_offline_test)
  target_include_directories(shiroha_peer_policy_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_peer_policy_offline COMMAND shiroha_peer_policy_offline_test)
endif()

# Compile only; this target is NEVER a CTest entry and never runs in L0.
option(SHIROHA_L1_CANDIDATE_BUILD "Compile unapproved future L1 probe" OFF)
if(SHIROHA_L1_CANDIDATE_BUILD)
  add_executable(shiroha_assoc_candidate diagnostics/association_probe.cpp)
  shiroha_native_settings(shiroha_assoc_candidate)
  target_include_directories(shiroha_assoc_candidate PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(shiroha_assoc_candidate PRIVATE psapi)
endif()

# Compile only; isolated L1-CRYPTO candidate links only pure memory core,
# CNG P-256 and crypt32 peer policy. Never a CTest entry and never runs in L0.
option(SHIROHA_L1_CRYPTO_CANDIDATE_BUILD "Compile unapproved future L1-CRYPTO probe (never run in CTest)" OFF)
if(SHIROHA_L1_CRYPTO_CANDIDATE_BUILD)
  add_executable(shiroha_l1_crypto_candidate diagnostics/l1_crypto_probe.cpp
    native_core.cpp native_crypto.cpp p256_key_codec.cpp crypto_windows.cpp
    peer_policy.cpp peer_policy_windows.cpp)
  shiroha_native_settings(shiroha_l1_crypto_candidate)
  target_compile_definitions(shiroha_l1_crypto_candidate PRIVATE SHIROHA_L1_CRYPTO_OBSERVATION)
  target_include_directories(shiroha_l1_crypto_candidate PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(shiroha_l1_crypto_candidate PRIVATE crypt32 bcrypt psapi)
endif()

if(SHIROHA_NATIVE_OFFLINE_TESTS)
  add_executable(shiroha_discovery_offline_test protected_objects.cpp association_files.cpp
    discovery_files.cpp tests/discovery_files_test.cpp)
  shiroha_native_settings(shiroha_discovery_offline_test)
  target_include_directories(shiroha_discovery_offline_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_discovery_offline COMMAND shiroha_discovery_offline_test)
  add_executable(shiroha_l1_crypto_probe_test tests/l1_crypto_probe_test.cpp)
  shiroha_native_settings(shiroha_l1_crypto_probe_test)
  target_include_directories(shiroha_l1_crypto_probe_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_l1_crypto_probe_offline COMMAND shiroha_l1_crypto_probe_test)
  # The exact Win32 wrappers, with every security API replaced by the forced
  # Fake header. No bcrypt/crypt32 link and no operational imports permitted.
  add_executable(shiroha_l1_crypto_observation_test
    tests/l1_crypto_observation_test.cpp native_core.cpp native_crypto.cpp
    p256_key_codec.cpp crypto_windows.cpp peer_policy.cpp peer_policy_windows.cpp)
  shiroha_native_settings(shiroha_l1_crypto_observation_test)
  target_compile_definitions(shiroha_l1_crypto_observation_test PRIVATE SHIROHA_L1_CRYPTO_OBSERVATION)
  target_compile_options(shiroha_l1_crypto_observation_test PRIVATE
    /FI"${CMAKE_CURRENT_SOURCE_DIR}/tests/l1_crypto_fake_win32.h")
  target_include_directories(shiroha_l1_crypto_observation_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_l1_crypto_observation_offline COMMAND shiroha_l1_crypto_observation_test)
  add_executable(shiroha_l1_crypto_admission_test tests/l1_crypto_admission_test.cpp)
  shiroha_native_settings(shiroha_l1_crypto_admission_test)
  target_include_directories(shiroha_l1_crypto_admission_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME shiroha_l1_crypto_admission_offline COMMAND shiroha_l1_crypto_admission_test)
endif()
