# The probe reuses :app's JNI shim source. That file's CMakeLists deliberately
# declares no project() -- in :app it is included from React Native's
# application CMake -- so the project() belongs here.
cmake_minimum_required(VERSION 3.22.1)
project(guestprobe)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../app/src/main/cpp rish_jni)
