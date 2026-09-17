# React Native's application setup, which defines `libappmodules.so` — the
# library that registers every TurboModule and Fabric component. Without it the
# app starts, finds no `PlatformConstants`, and aborts before rendering.
#
# This file lives in its own directory on purpose: ReactNative-application.cmake
# globs `*.cpp` next to it and, if it finds any, uses those *instead of* its own
# OnLoad.cpp. The JNI shims therefore stay in ../cpp and are pulled in below.
cmake_minimum_required(VERSION 3.22.1)

project(appmodules)

include(${REACT_ANDROID_DIR}/cmake-utils/ReactNative-application.cmake)

# The Rish JNI shims, built from their own directory so their sources are never
# mistaken for an OnLoad override.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../cpp rish_jni)
