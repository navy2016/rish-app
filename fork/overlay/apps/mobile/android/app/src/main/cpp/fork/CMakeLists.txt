cmake_minimum_required(VERSION 3.22.1)

# Fork entry point, selected by the fork patch in android/app/build.gradle.
# It must keep building the framework's application-level library: OnLoad.cpp
# installs the TurboModule and Fabric component providers the runtime needs at
# startup, and DefaultSoLoader loads libappmodules.so to reach them (without it
# the first TurboModuleRegistry lookup, PlatformConstants, aborts the app).
#
# This file lives in ./fork/ on purpose: ReactNative-application.cmake treats
# any *.cpp in the entry file's own directory as a replacement OnLoad.cpp, and
# the upstream shim sources stay exactly where upstream keeps them (../).
project(appmodules)

include(${REACT_ANDROID_DIR}/cmake-utils/ReactNative-application.cmake)

# Both Rust libraries are staged as prebuilt cdylibs per ABI plus their
# headers — the guest runtime by scripts/prepare-rish-android.sh, the agent
# core by scripts/prepare-rish-agent-core-android.sh. Gradle passes whichever
# staging directories exist; nothing here downloads or builds Rust, and each
# shim is built only when its own runtime is staged.
if(NOT DEFINED RISH_FFI_DIR AND NOT DEFINED RISH_AGENT_CORE_DIR)
  message(FATAL_ERROR "RISH_FFI_DIR or RISH_AGENT_CORE_DIR is required; run scripts/prepare-rish-android.sh first")
endif()

# Rust cdylibs carry no ELF SONAME by default. Without IMPORTED_NO_SONAME,
# CMake can record the build-machine absolute path in DT_NEEDED instead of the
# bare file name the Android loader resolves from nativeLibraryDir.
function(rish_import_staged_library target directory library)
  set(path "${directory}/jniLibs/${ANDROID_ABI}/${library}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "no staged ${library} for ${ANDROID_ABI}: ${path}")
  endif()
  add_library(${target} SHARED IMPORTED)
  set_target_properties(
    ${target}
    PROPERTIES IMPORTED_LOCATION "${path}" IMPORTED_NO_SONAME TRUE
  )
endfunction()

function(rish_add_shim target source directory linked)
  add_library(${target} SHARED "${source}")
  target_include_directories(${target} PRIVATE "${directory}/include")
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_options(${target} PRIVATE -fvisibility=hidden -Wall -Wextra)
  target_link_libraries(${target} PRIVATE ${linked})
endfunction()

if(DEFINED RISH_FFI_DIR)
  rish_import_staged_library(rish_ffi "${RISH_FFI_DIR}" librish_ffi.so)
  rish_add_shim(rish_guest_jni "${CMAKE_CURRENT_LIST_DIR}/../rish_guest_jni.cpp"
                "${RISH_FFI_DIR}" rish_ffi)
endif()

if(DEFINED RISH_AGENT_CORE_DIR)
  rish_import_staged_library(rish_agent_ffi "${RISH_AGENT_CORE_DIR}" librish_agent_ffi.so)
  rish_add_shim(rish_agent_core_jni "${CMAKE_CURRENT_LIST_DIR}/../rish_agent_core_jni.cpp"
                "${RISH_AGENT_CORE_DIR}" rish_agent_ffi)
endif()
