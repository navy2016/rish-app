#!/bin/sh
# Runs the Android workspace acceptance test on the booted emulator. Invoked as
# a single command: android-emulator-runner executes each script line in its
# own shell, so state cannot survive between lines.
set -eu

cd "$GITHUB_WORKSPACE/apps/mobile/android"
./gradlew :app:connectedDebugAndroidTest \
  -PreactNativeArchitectures=x86_64 \
  -PrishStandalone=true \
  -Pandroid.testInstrumentationRunnerArguments.class=tech.zseven.rish.AndroidWorkspaceStoreTest
