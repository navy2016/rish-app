#!/bin/sh
# Apply this fork's Android overlay over a pristine upstream checkout.
#
# The fork keeps no modifications to upstream files in git. The android
# workflows run this script right after checkout so the built tree matches
# what the fork expects:
#   - fork/overlay/** holds full files copied over the checkout (mirrors the
#     repository layout);
#   - fork/patches/** holds git-apply patches (currently one small patch for
#     apps/mobile/android/app/build.gradle).
set -eu

cd "$(git rev-parse --show-toplevel)"

cp -a fork/overlay/. .

git apply fork/patches/android-app-build.gradle.patch

echo "fork overlay applied; changed paths:"
git status --short
