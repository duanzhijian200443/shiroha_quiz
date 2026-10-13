cmake_minimum_required(VERSION 3.14)
project(shiroha_external_native LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR
   NOT CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "x64")
  message(FATAL_ERROR "External Native Helper requires Windows x64")
endif()

function(shiroha_native_settings target)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN SHIROHA_EXTERNAL_NATIVE_BUILD)
  target_compile_options(${target} PRIVATE /W4 /WX /EHsc /GS)
  target_link_options(${target} PRIVATE /DYNAMICBASE /NXCOMPAT /GUARD:CF)
  target_compile_options(${target} PRIVATE /guard:cf)
endfunction()

add_library(shiroha_external_native SHARED native_core.cpp native_windows.cpp
  protected_objects.cpp association_files.cpp protected_windows.cpp)
shiroha_native_settings(shiroha_external_native)
target_link_libraries(shiroha_external_native PRIVATE crypt32 shell32 ole32 uuid advapi32 bcrypt)

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
endif()
