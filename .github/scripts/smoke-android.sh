#!/bin/sh
# Launch the release APK on the running emulator and fail on a startup crash.
# Invoked as a single command from the android-emulator-runner script input,
# which executes each line in its own shell (no variables survive lines).
set -eu

APK="$GITHUB_WORKSPACE/apps/mobile/android/app/build/outputs/apk/release/app-release.apk"
test -f "$APK"

adb install -r "$APK"
adb shell am start -W -n tech.zseven.rish/.MainActivity
sleep 30

if [ -z "$(adb shell pidof tech.zseven.rish)" ]; then
  echo "app process is not alive after launch" >&2
  adb logcat -d | tail -n 300 >&2 || true
  exit 1
fi

adb logcat -d > "$RUNNER_TEMP/logcat.txt" || true
if grep -E "FATAL EXCEPTION|PlatformConstants could not be found|JavascriptException|Abort message|UnsatisfiedLinkError" "$RUNNER_TEMP/logcat.txt"; then
  echo "startup crash detected" >&2
  exit 1
fi

echo "SMOKE OK: app process is alive with no startup crash"
