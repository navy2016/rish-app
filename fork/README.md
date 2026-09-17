# Fork overlay

This fork tracks upstream [`ZSeven-W/rish-app`](https://github.com/ZSeven-W/rish-app).
It carries **no modifications to upstream files** — everything the fork adds
lives in files upstream does not have, so `git merge upstream/main` stays a
clean, conflict-free operation.

```
.github/workflows/android-release.yml   fork-only: signed arm64 release builds
.github/workflows/android-smoke.yml     fork-only: emulator smoke + device acceptance
.github/scripts/*.sh                    helpers for the two workflows above
fork/overlay/**                         full files copied over the checkout before building
fork/patches/**                         git-apply patches applied after the overlay
```

Both android workflows run `.github/scripts/apply-fork-overlay.sh` immediately
after checkout:

1. `cp -a fork/overlay/. .` — copies the fork's Android sources into place
   (the overlay mirrors the repository layout);
2. `git apply fork/patches/android-app-build.gradle.patch` — rewires
   `android/app/build.gradle` to the fork CMake entry and drops the CMake
   `targets` filter (the filter would omit the framework's `libappmodules.so`,
   whose absence aborts startup with
   `TurboModuleRegistry.getEnforcing(...): 'PlatformConstants' could not be found`).

## What the overlay contains

| Path (under `fork/overlay/`) | Why |
| --- | --- |
| `apps/mobile/android/app/src/main/java/tech/zseven/rish/modules/LocalMirrorsModule.kt` | upstream still rejects every call; the fork stages the mirror overlay for real |
| `.../modules/LocalWorkspaceModule.kt` | upstream placeholder; the fork serves file operations (list/read/write/mkdir/rename/trash/restore/portable tools) |
| `.../modules/LocalWorkspacesModule.kt` | upstream placeholder; the fork registers workspaces and drives the system folder picker (SAF) |
| `.../runtime/AndroidWorkspaceStore.kt` | the fork's workspace authority + storage layer used by the three modules above |
| `androidTest/java/tech/zseven/rish/AndroidWorkspaceStoreTest.kt` | device acceptance test run by the smoke workflow |
| `apps/mobile/android/app/src/main/cpp/fork/CMakeLists.txt` | fork CMake entry: keeps building the framework's `libappmodules.so` and adds the upstream JNI shims (`../rish_*_jni.cpp`) |
| `fork/patches/android-app-build.gradle.patch` | points `externalNativeBuild` at the fork CMake entry; drops the `targets` filter |

## Syncing with upstream

```sh
git fetch upstream
git merge upstream/main
git push
```

No conflicts should appear: upstream files are byte-identical to upstream.

Maintenance notes:

- If upstream edits `android/app/build.gradle` around the patched lines,
  `git apply` fails loudly in CI — regenerate the patch against the new
  upstream file (same two changes: fork CMake path, no `targets`).
- If upstream implements a module the overlay replaces (e.g. a real
  `LocalWorkspacesModule`), delete the corresponding overlay file (or the
  whole overlay) instead of rebasing anything.
