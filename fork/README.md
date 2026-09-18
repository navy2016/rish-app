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

Gradle tasks are scoped to `:app:` (`:app:assembleRelease`, `:app:assembleDebug`,
`:app:assembleDebugAndroidTest`). A bare `assembleRelease` matches **every**
subproject that has the task — including upstream's unrelated `:guestprobe`
probe APK (added upstream in `812fcb0`) — so the fork names the module it
actually delivers. `:guestprobe` still gets *configured* (it throws at
configuration time when no runtime is staged), which is why both workflows
stage the guest runtime before any Gradle step.

## What the overlay contains

| Path (under `fork/overlay/`) | Why |
| --- | --- |
| `apps/mobile/android/app/src/main/java/tech/zseven/rish/modules/LocalRuntimeModule.kt` | upstream lacks `bootstrapForHarness` (the JS runtime probe needs it for every non-dsh harness) and its rejections drop the HTTP status; the overlay adds both, no other behaviour change |
| `apps/mobile/android/app/src/main/java/tech/zseven/rish/modules/LocalMirrorsModule.kt` | upstream still rejects every call; the fork stages the mirror overlay for real |
| `.../modules/LocalWorkspaceModule.kt` | upstream placeholder; the fork serves bounded file operations (list/read/write/mkdir/rename/trash/restore/portable tools) over the shared registry's proven root, with a fallback to folders the fork imported before the registry existed |
| `.../runtime/AndroidWorkspaceStore.kt` | the fork's file-operation engine; it also answers records the fork created before the shared registry existed |
| `scripts/prepare-rish-agent-core-android.sh` | upstream hardcodes arm64-v8a; the overlay accepts `RISH_ANDROID_ABIS=x86_64` (same contract as `prepare-rish-android.sh`) so the smoke emulator stages a core and its session acceptance runs against the real core |
| `.../modules/LocalWorkspacesModule.kt` | upstream refuses folder picking; the overlay drives the Storage Access Framework picker and **imports**: the picked tree is copied into a new owned workspace (bounded: 20000 entries / 1 GiB), which binds and runs like any other. Regrant/forget/delete still refuse. |
| `.../runtime/AndroidProviderConfiguration.kt` | dsh becomes a configurable harness: a custom service (endpoint, protocol, auth, mappings) may be saved for it like codex/claude-code, and `CUSTOM_PROVIDER_dsh_` accounts re-prompt per profile |
| `.../runtime/AndroidCredentialStore.kt` | accepts `CUSTOM_PROVIDER_dsh_<sha256>` account names |
| `.../runtime/AndroidSessionEnvironment.kt` | supplies `provider_bindings` answers (canonical keyed by the core's own canonicalisation) so a session whose receipts carry a custom-service binding can be judged and persisted; upstream returned an empty list, which refused every such session |
| `apps/mobile/src/providers/configuration.ts` | `ConfigurableHarness` (and binding parsing) includes dsh |
| `apps/mobile/src/components/ProviderConfigurationCard.tsx` | the custom-service card is offered for dsh too (mapping list = the bundled dsh models) |
| `apps/mobile/android/app/src/androidTest/java/tech/zseven/rish/AndroidWorkspaceStoreTest.kt` | device acceptance test run by the smoke workflow |
| `apps/mobile/android/app/src/androidTest/java/tech/zseven/rish/AndroidRuntimeBootstrapTest.kt` | device acceptance test for the runtime probe (`bootstrapForHarness`) run by the smoke workflow |
| `apps/mobile/android/app/src/androidTest/java/tech/zseven/rish/AndroidWorkspaceBridgeTest.kt` | device acceptance test for the registry→store file bridge run by the smoke workflow |

Upstream `fbc8413` (2026-09-17) made Android workspaces real: a shared
`AndroidWorkspaceRegistry` sealed by the core, a `LocalWorkspacesModule` that
answers create/list/resolve/queryOperation, and a root resolver that
`LocalProjects.projectForWorkspaceV2` consults — which is what finally lets a
person bind a workspace on Android. The fork therefore **deleted its
`LocalWorkspacesModule` overlay** and no longer owns a workspace registry:
choosing a folder outside the app stays refused (upstream has not built the
Storage Access Framework side), and the Files surface resolves what a bind
produced through the deleted module's replacement above.

The smoke workflow's acceptance run also executes upstream's
`AndroidRuntimeStoreTest` (session CAS persist/load/query — the chain the local
chat persistence runs through) so a regression there fails the fork's build,
not just upstream's never-run suite.

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
