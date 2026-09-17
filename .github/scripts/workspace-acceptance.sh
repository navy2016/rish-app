#!/bin/sh
# Runs the Android device acceptance tests on the booted emulator:
#   - AndroidWorkspaceStoreTest     fork workspace authority suite
#   - AndroidRuntimeBootstrapTest   fork runtime probe (bootstrapForHarness)
#   - AndroidRuntimeStoreTest       upstream session CAS chain (persist/load/
#     query + digest vector + credential store) — the exact path the local
#     chat persistence runs through, so a regression fails this run.
# Invoked as a single command: android-emulator-runner executes each script
# line in its own shell, so state cannot survive between lines.
set -eu

cd "$GITHUB_WORKSPACE/apps/mobile/android"
./gradlew :app:connectedDebugAndroidTest \
  -PreactNativeArchitectures=x86_64 \
  -PrishStandalone=true \
  -Pandroid.testInstrumentationRunnerArguments.class=tech.zseven.rish.AndroidWorkspaceStoreTest,tech.zseven.rish.AndroidRuntimeBootstrapTest,tech.zseven.rish.AndroidRuntimeStoreTest
