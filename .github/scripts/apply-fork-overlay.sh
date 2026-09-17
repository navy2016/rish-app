#!/bin/sh
# Copy this fork's Android overlay over a pristine upstream checkout.
#
# The fork keeps no modifications to upstream files in git. The android
# workflows run this script right after checkout so the built tree matches
# what the fork expects: fork/overlay/** holds full files copied over the
# checkout (the overlay mirrors the repository layout). There are no patches.
set -eu

cd "$(git rev-parse --show-toplevel)"

cp -a fork/overlay/. .

echo "fork overlay applied; changed paths:"
git status --short
