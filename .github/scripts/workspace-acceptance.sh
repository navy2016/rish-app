#!/bin/sh
# Runs the Android device acceptance tests on the booted emulator:
#   - AndroidWorkspaceStoreTest     fork workspace authority suite
#   - AndroidRuntimeBootstrapTest   fork runtime probe (bootstrapForHarness)
#   - AndroidWorkspaceBridgeTest    fork bridge: registry workspace -> store file ops
#   - AndroidTransportReplyTest     fork: what a chat reply must answer before
#     anything reads it (a tool-call reply is not an empty answer)
#   - plus upstream's native suites: session CAS chain (the exact path the
#     local chat persistence runs through), core bindings, workspace registry,
#     workspace tool rules/executor, prepared attempts, agent journals/WAL,
#     tool batch/execution/registry, transport tools, root resolver.
# Invoked as a single command: android-emulator-runner executes each script
# line in its own shell, so state cannot survive between lines.
set -eu

cd "$GITHUB_WORKSPACE/apps/mobile/android"
./gradlew :app:connectedDebugAndroidTest \
  -PreactNativeArchitectures=x86_64 \
  -PrishStandalone=true \
  -Pandroid.testInstrumentationRunnerArguments.class=tech.zseven.rish.AndroidWorkspaceStoreTest,tech.zseven.rish.AndroidRuntimeBootstrapTest,tech.zseven.rish.AndroidWorkspaceBridgeTest,tech.zseven.rish.AndroidTransportReplyTest,tech.zseven.rish.AndroidRuntimeStoreTest,tech.zseven.rish.AndroidCoreBindingsTest,tech.zseven.rish.AndroidWorkspaceToolExecutorTest,tech.zseven.rish.AndroidWorkspaceRegistryTest,tech.zseven.rish.AndroidPreparedAttemptStoreTest,tech.zseven.rish.AndroidAgentRootResolverTest,tech.zseven.rish.AndroidAgentRoundJournalTest,tech.zseven.rish.AndroidAgentRoundTest,tech.zseven.rish.AndroidAgentToolRegistryTest,tech.zseven.rish.AndroidAgentTranscriptStoreTest,tech.zseven.rish.AndroidAgentWalTest,tech.zseven.rish.AndroidWorkspaceToolRuleTest,tech.zseven.rish.AndroidTransportToolsTest,tech.zseven.rish.AndroidAgentToolBatchTest,tech.zseven.rish.AndroidAgentToolExecutionTest
