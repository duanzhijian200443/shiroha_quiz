cmake_minimum_required(VERSION 3.14)
project(shiroha_relay_native LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Local relay requires Windows x64")
endif()
add_library(shiroha_relay_native SHARED local_relay.cpp)
target_compile_features(shiroha_relay_native PRIVATE cxx_std_17)
target_compile_definitions(shiroha_relay_native PRIVATE
  UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(shiroha_relay_native PRIVATE /W4 /WX /EHsc /GS /guard:cf)
target_link_options(shiroha_relay_native PRIVATE /DYNAMICBASE /NXCOMPAT /GUARD:CF)
target_link_libraries(shiroha_relay_native PRIVATE advapi32 bcrypt user32)
