# Fork overlay

This fork tracks upstream [`ZSeven-W/rish-app`](https://github.com/ZSeven-W/rish-app).
It carries **no modifications to upstream files** — everything the fork adds
lives in files upstream does not have, so `git merge upstream/main` stays a
clean, conflict-free operation.

```
.github/workflows/android-release.yml   fork-only: signed arm64 release builds
.github/workflows/android-smoke.yml     fork-only: emulator smoke + device acceptance
.github/scripts/apply-fork-overlay.sh   copies fork/overlay over the CI checkout
.github/scripts/smoke-android.sh        emulator helpers for the two workflows
.github/scripts/workspace-acceptance.sh
fork/overlay/**                         full files copied over the checkout before building
```

Both android workflows run `.github/scripts/apply-fork-overlay.sh` immediately
after checkout; the script copies `fork/overlay/.` over the repository (the
overlay mirrors the repository layout). There are no patches: upstream commit
`fe61371` ("Build libappmodules.so…", 2026-09-17) now builds the appmodules
library in its own `src/main/jni` CMake entry, so the fork's CMake override and
its small `android/app/build.gradle` patch were deleted.

## What the overlay contains

| Path (under `fork/overlay/`) | Why |
| --- | --- |
| `apps/mobile/android/app/src/main/java/tech/zseven/rish/modules/LocalMirrorsModule.kt` | upstream still rejects every call; the fork stages the mirror overlay for real |
| `.../modules/LocalWorkspaceModule.kt` | upstream placeholder; the fork serves file operations (list/read/write/mkdir/rename/trash/restore/portable tools) |
| `.../modules/LocalWorkspacesModule.kt` | upstream placeholder; the fork registers workspaces and drives the system folder picker (SAF) |
| `.../runtime/AndroidWorkspaceStore.kt` | the fork's workspace authority + storage layer used by the three modules above |
| `apps/mobile/android/app/src/androidTest/java/tech/zseven/rish/AndroidWorkspaceStoreTest.kt` | device acceptance test run by the smoke workflow |

## Syncing with upstream

```sh
git fetch upstream
git merge upstream/main
git push
```

No conflicts should appear: upstream files are byte-identical to upstream.
The overlay is copied only in CI checkouts, so a merge never touches it. If
upstream implements one of the bridges above, delete the corresponding overlay
file instead of rebasing anything.
