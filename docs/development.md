# Development and runtime reference

[Back to Rish](../README.md) · [中文说明](../README.zh.md)

This guide contains implementation detail, build commands, and validation
procedures. Run shell commands from the repository root unless stated otherwise.
For a capability overview, start with the README.

## iOS build prerequisites

The native preparation scripts currently require an Apple Silicon Mac, Xcode
26.6 (build 17F113), iOS and Simulator SDK 26.5, Rust toolchain `1.94` resolving
to rustc 1.94.1, and the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets.
These are enforced pins, not a claim of compatibility with arbitrary versions.
Node 22.11+, CocoaPods, CMake, Perl, make, Git, jq, and the script-checked tools
must be available. The first preparation downloads pinned sources and dependencies.

The project ships without a signing team. Simulator builds need none; device
builds need your own Apple Developer team, set in Xcode under Signing &
Capabilities or passed to `xcodebuild` as `DEVELOPMENT_TEAM=<team id>` with
`-allowProvisioningUpdates`. Developer scripts that read API keys
(`scripts/provision-simulator-key.rb`, `scripts/probe-deepseek-vision.rb`) take
`DSH_CREDENTIALS`, a 0600 YAML file you own; there is no default path, and
`--secure-stdin` reads the key from the terminal instead.

The app lives in `apps/mobile` and renders native React Native views with
Fabric and Hermes. DSH was the first built-in Harness target; Rish's scope
extends to multiple model providers and task types.

The original Swift/WebKit shell is retired and kept only for provenance in
[`legacy/web-proxy/`](../legacy/web-proxy/README.md). No target builds it.
`run-simulator.sh` builds and launches the React Native product; it never
starts or embeds that baseline.

## Product documentation

Rish App product designs, stable interface specs, plans, and evidence are
maintained separately from this source repository. This README is the public
implementation and runtime boundary; do not infer completed behavior from a
design document.

The current contribution and security policies are drafts: see
[CONTRIBUTING.md](../CONTRIBUTING.md) and [SECURITY.md](../SECURITY.md). The project
source is licensed under the [MIT License](../LICENSE), and the current status of
private vulnerability reporting is recorded in `SECURITY.md`.
The current limited dependency inventory is in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md); it is not a complete SBOM.
The planned `v0.1.0` source-preview scope and release checklist are in
[`docs/releases/v0.1.0.md`](releases/v0.1.0.md); no tag or release is
created by that document.

## Honest runtime boundary

| Mode              | What runs on the phone                                                                                                     | Current status             |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| `web_proxy`       | UI only; DSH runs elsewhere                                                                                                | Historical WebKit baseline |
| `local_substrate` | Native model transport, secure credential storage, local sessions, bounded workspace operations, and rish portable applets | Implemented on iOS         |
| `local_harness`   | One selected Harness runtime, agent loop, event log, registered tools, approvals, and persistence                          | Partially implemented; gate not closed |

The app must continue to identify itself as `local_substrate` until the selected
Harness has passed the complete local_harness gate. Existing AgentLoop,
controller, tool and approval code, or a local model request plus a few local
tools, is not by itself a complete local Harness runtime.

## Custom providers (iOS)

Select **Claude Code** or **Codex**, then open **Settings → Custom provider**.
Enter the service address, choose Messages, Responses, or Chat Completions, and
map the existing model slots to the service's model IDs. Empty mappings use the
original model ID. Full endpoint mode preserves a custom API path; otherwise
Rish fills in the selected protocol's standard path.

Save the settings, then use **Configure key** to save that service's API key in
the native Keychain prompt. Official and custom credentials remain separate.
Changing services requires project context to be confirmed again. Disable the
custom provider and save to return to the official configuration.

## Current mobile product

The following describes the iOS surface unless another platform is named.

- The Agent permissions panel reads current native workspace/project policy
  on opening, refresh and foreground return, without creating a task or using
  model credentials. It shows native tool modes and matching conversation grants.
  Local Documents-owned workspaces can enable Git from this panel: files stay
  in place, the private Git backend is attached, and a new Git-bound chat is
  opened while the original chat is retained. Active tasks and pending saves
  must finish before this binding transition.
- Multiple local conversations: create, search, switch, auto-title, rename,
  delete with confirmation, and restore after process restart.
- Per-conversation DeepSeek V4 Flash, V4 Pro, or multimodal Flash Vision Exp selection, complete multi-turn
  history, request-scoped Stop, retry, and rejection of late responses.
- Composer attachments from Camera, Photos, and iOS Files. Images use the
  native Flash Exp multimodal request path; UTF-8 text files are bounded and
  delimited, and PDFs use bounded PDFKit text extraction. Attachment-only
  messages, retry, history cards, restart recovery, and clickable native Quick
  Look previews are supported.
- Composer-level thinking modes (`off`, `high`, and `max`) persisted per conversation and sent through the native DeepSeek
  transport. Returned reasoning can be persisted, hidden, and expanded.
- A mobile Markdown subset for headings, bullets, block quotes, inline code,
  fenced code, bounded tables and math, and controlled image display. Plain
  URLs, bold URLs, and Markdown links open on an explicit tap; user messages
  also support plain URL links. Code spans stay literal, and unsupported URL
  schemes are not actionable.
- Agent round presentation places returned progress text and optional
  reasoning before that round's tool cards, followed by the final answer.
  The bounded, owner-checked iOS presentation archive survives transcript
  cleanup and process restart; it does not replay tools. Reasoning display
  follows the user's setting and depends on what the model returns. Text
  already discarded by older builds cannot be reconstructed.
- A right-side animated Settings drawer with system/light/dark appearance,
  system/Simplified Chinese/English locale, default model, thinking display,
  tool-card behavior, local workspace permission, destructive-action
  confirmation, credential management, package mirrors, and runtime evidence.
- Alpine APK, Python pip, and Node npm mirror settings support presets, custom
  HTTPS bases, bounded speed tests, persistence, and native staging for the
  rish guest. The UI explicitly reports that the persistent guest is not
  mounted yet.
- On-demand language environments install verified Python, Java, Go, Rust,
  Bun and Node.js disks independently. An explicit Run action executes a
  bounded workspace copy in the real guest, with stdout/stderr, exit state
  and interruptible cancellation. Environment packages are cached; execution
  disks are disposable. See [language environments](runtime-environments.md).
- A right-side local Files drawer with nested directory navigation, text-file
  create/read/edit, revision-protected atomic save, rename, recoverable trash,
  restore, and real `sha256sum`/`wc` rish receipts. Files and folders can be
  imported from and exported to the iOS Files app through the native document
  picker; security-scoped provider URLs never cross into JavaScript.
- App-owned Git Projects backed by pinned libgit2: create, public HTTPS clone,
  native SSH clone/fetch with pinned libssh2/OpenSSL and strict `known_hosts`,
  status, unified diff, stage all, commit, configure `origin`, native Keychain
  credentials, and non-force HTTPS push. SSH profile picker/restart UI and SSH
  push remain outside the verified surface. Each conversation can bind to one
  opaque project id, and project Files stay scoped to that worktree while `.git`
  remains hidden from the normal file API.
- A mobile-specific runtime evidence surface and a machine-verifiable proof
  record that correlates the DeepSeek response, optional reasoning, persisted
  session, process restart, rish execution, live Simulator PID, and a closed
  Mac DSH port.
- One Lucide-based functional icon system across chat, drawers, settings,
  projects, Git, Files, attachments, and tool states. Icons use per-icon imports
  and a shared 1.8-stroke wrapper; semantic text markers, data symbols, status
  dots, and the Rish brand mark remain intentionally separate.

The original app icon is stored in `brand/`. It intentionally uses the
geometric DSH mark without the whale or any plugin artwork. Lucide is used for
interface actions only and does not replace the product mark.

## Architecture

```text
React Native mobile UI (Fabric + Hermes)
  -> typed chat/preferences stores and mobile presentation layer
  -> bounded native modules
       LocalRuntime
         -> iOS Keychain (credential never crosses into JavaScript)
         -> native URLSession -> DeepSeek
         -> App Container sessions + runtime proof
         -> linked rish sha256sum proof probe
       LocalWorkspace
         -> app-owned workspace only
         -> descriptor-relative, no-symlink file operations
         -> atomic revision-checked text writes + recoverable trash
         -> allowlisted read-only rish portable applets
       LocalDocuments
         -> UIDocumentPicker import/export bridge to the iOS Files app
         -> bounded staged copies; no external provider URL reaches JavaScript
         -> reserved Git metadata and symlinks fail closed
       LocalAttachments
         -> Camera, PHPicker, and UIDocumentPicker acquisition
         -> opaque-id native store with normalized images and bounded previews
         -> SHA-256 manifests, lifecycle pruning, and no file paths in chat JSON
       LocalProjects
         -> app-private, isolated Git worktrees resolved from opaque ids
         -> pinned libgit2 XCFramework using iOS SecureTransport
         -> pinned libssh2/OpenSSL SSH transport
         -> native HTTPS credential prompt + device-only Keychain storage
```

These native modules currently use the legacy React Native bridge. A production
hardening step is to migrate the same narrow contracts to Codegen TurboModules;
it is not permission to expose arbitrary paths, provider URLs, credentials, or
a general shell to JavaScript.

## Security invariants

- API keys are never committed, bundled, logged, persisted in chat/session
  JSON, or returned to React Native. On iOS they are stored as
  `WhenUnlockedThisDeviceOnly` Keychain items and used only by native code.
- The Simulator provisioner uses a temporary `0600` staging file, waits for a
  value-free acknowledgement, and removes the staged value after Keychain
  import. Prefer `--secure-stdin` when not importing the managed DSH
  credential.
- Workspace paths are relative to the app-owned workspace. Absolute paths,
  traversal, `.trash`, symlinks, non-text/oversized reads, excessive listings,
  and non-allowlisted tools fail closed.
- iOS Files access is explicit import/export, not unrestricted filesystem
  access. Imports are bounded and staged before publication. Exports copy to a
  temporary sanitized tree and omit `.git`, `.gitmodules`, and app trash.
- Chat attachments are copied into an app-owned 256 MiB native store. Messages
  persist only opaque descriptors; thumbnails, provider URLs, absolute paths,
  and base64 image payloads are excluded from session JSON. Images are
  metadata-stripped and downsampled before sending.
- Git remote URLs are validated before credentials are used. HTTPS uses
  credential-free public DNS origins with PATs in native
  `WhenUnlockedThisDeviceOnly` Keychain storage; SSH profiles keep their
  private material in native storage and require strict `known_hosts`.
  Encrypted SSH private-key formats, force push, LFS, and submodules are
  rejected in the current surface.
- Read-only mode disables create, edit, rename, and trash controls. Saves use
  an expected revision to detect stale edits, and deletion means a recoverable
  move to app trash.
- Run `scripts/verify-no-bundled-secret.rb` before sharing an app bundle. Never
  place a key in source, shell history, a README, an environment file, or a
  test fixture.

## Install and run the React Native app

Node 22.11 or newer is required. From the repository root, check the source
layout before installing dependencies:

```sh
node scripts/verify-source-checkout.mjs
npm ci --prefix apps/mobile
```

The preflight runs offline and checks required source files, portable build
references, native entry points, and the npm lockfile. It does not compile
native code or prepare dependencies.

All iOS builds, including Metro-backed development builds, require the
vendored native frameworks before CocoaPods installation. Run this shared
preparation from the repository root:

```sh
./scripts/prepare-rish-ios.sh
./scripts/prepare-rish-agent-core.sh
./scripts/prepare-libgit2-ios.sh
cd apps/mobile/ios
pod install
cd ../../..
```

The default Rish preparation fetches the pinned source commit into an
isolated temporary checkout and downloads missing Cargo dependencies with
`--locked`. The actual builds use `--frozen`; dependency versions stay pinned.
To reuse a reviewed clean source checkout, pass its path to
`prepare-rish-ios.sh` or set `RISH_SOURCE_DIR`.

For an explicitly offline Rish preparation, the pinned Rust toolchain and
targets must already be installed, the Cargo cache must be populated, and a
reviewed source checkout must be supplied:

```sh
RISH_IOS_OFFLINE=1 RISH_SOURCE_DIR=/path/to/rish ./scripts/prepare-rish-ios.sh
```

This option disables source fetching and enables Cargo's offline mode for
Rish preparation. It does not make npm, CocoaPods, or the separate native
dependency preparation scripts offline.

The iOS dependency bootstrap requires Rust/Cargo, Xcode command-line tools,
CocoaPods, Perl, `make`, and CMake on `PATH`, plus the tools checked by the
preparation scripts. On macOS, CMake can be installed with
`brew install cmake`; an absolute override is also supported:

```sh
CMAKE_BIN=/absolute/path/to/cmake ./scripts/prepare-libgit2-ios.sh
```

`prepare-libgit2-ios.sh` automatically invokes the pinned libssh2 and OpenSSL
preparation helpers, so they do not need to be run separately.

After the shared iOS preparation, start a Metro-backed development run from
the repository root:

```sh
npm run ios --prefix apps/mobile
```

For Android UI development, after the npm installation above:

```sh
npm run android --prefix apps/mobile
```

Android task alerts, per-conversation mute, and user-started foreground-service
lifecycle are implemented and have scoped emulator tests. Android uses an
ongoing notification instead of iOS Live Activities. These checks do not prove
model, file/Git, or Agent execution.

Android now supports pure-text API chat through native OkHttp, Android Keystore
encrypted credentials, scoped custom-provider profiles, and atomic SQLite session
snapshots. API33 emulator checks cover DSH, GLM, GLM-backed Codex/Claude Code
profiles, and UI send/save/reopen without replay. Those profiles test API adapters,
not the official CLI harnesses or subscription login. Attachments, project context,
file/Git, and Agent execution remain unavailable; runtime status honestly
reports incomplete. Debug UI uses Metro; standalone Release and physical Android
device acceptance remain pending.

### Android guest runtime

The rish Linux guest runs on Android through the same pure-Rust x86_64
interpreter the iOS app uses. It is opt-in at build time because it adds the
runtime library and the 22 MB of guest boot assets to the APK:

```sh
scripts/prepare-rish-android.sh
apps/mobile/android/gradlew -p apps/mobile/android :app:assembleDebug -PreactNativeArchitectures=arm64-v8a
```

`prepare-rish-android.sh` carries the same rish commit, `rish.h`, `Cargo.lock`
and Rust pins as `prepare-rish-ios.sh`, builds `rish-ffi` with the pinned NDK
(27.1.12297006, API 24, 16 KiB page alignment), verifies the ELF machine,
segment alignment, Bionic-only dependencies and exported symbols, and stages
`apps/mobile/android/rish-ffi/` (gitignored) with a provenance manifest.
`RISH_ANDROID_ABIS` selects ABIs (default `arm64-v8a`; `x86_64` needs the
`x86_64-linux-android` Rust target). Gradle packages the runtime, compiles the
JNI shim under `app/src/main/cpp/`, and copies the pinned kernel and initramfs
from `apps/mobile/ios/Rish/GuestAssets/` into the APK assets; it refuses a
`reactNativeArchitectures` set the runtime was not staged for. Without the
staged directory the build stays a lite build and `LocalGuest` reports
`implemented = false`.

`LocalGuestModule` (Kotlin, `tech.zseven.rish.guest`) mirrors the iOS module:
fail-closed request validation, digest verification of the staged assets before
every boot, one session per process, boot on a dedicated thread, exec
serialised with shutdown, and receipts that never carry paths. JVM unit tests
cover the state machine against a fake runtime; the instrumented
`LocalGuestBootTest` is the real proof and skips on a lite build:

```sh
apps/mobile/android/gradlew -p apps/mobile/android :app:connectedDebugAndroidTest \
  -PreactNativeArchitectures=arm64-v8a \
  -Pandroid.testInstrumentationRunnerArguments.class=tech.zseven.rish.LocalGuestBootTest
```

On the arm64 API 33 emulator it boots the guest in about 34 s with 768 MiB,
reports `uname -m` as `x86_64`, installs `tree` from the offline apk repository
baked into the initramfs, runs it, and shuts down. This proves the runtime and
guest are genuinely in the APK and bootable; nothing in the Android UI drives
the guest yet, because the Agent runtime, workspace and file modules that use
it on iOS are still unavailable on Android.

For temporary Android compatibility-container testing, build a self-contained
debug-signed APK with bundled JS and developer-server support disabled:

```sh
apps/mobile/android/gradlew -p apps/mobile/android :app:assembleDebug -PrishStandalone=true -PreactNativeArchitectures=arm64-v8a
```

This remains a test build, not a production-signed release. Its launcher was
checked on the API33 emulator with airplane mode enabled; HarmonyOS compatibility
container installation and execution require a separate device check.

### Android release signing

Release builds never use the React Native debug keystore. `assembleRelease`,
`bundleRelease` and `installRelease` fail with an explanation unless you supply
a key, either as `apps/mobile/android/keystore.properties` (gitignored):

```properties
storeFile=/absolute/or/android-relative/path/to/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

or as the environment `RISH_ANDROID_KEYSTORE`, `RISH_ANDROID_KEYSTORE_PASSWORD`,
`RISH_ANDROID_KEY_ALIAS` and `RISH_ANDROID_KEY_PASSWORD` for CI. A properties
file that points at `debug.keystore` is refused. Debug builds keep the debug
key, and unit tests and configuration never need release signing.

## Editable DSH model catalog

In Settings, use **DSH model catalog** to add exact provider model IDs, display
names and image-input capability declarations, or edit/remove entries and restore
defaults. iOS and Android persist the catalog natively. Up to 32 selectable models
are supported; removed identities remain readable in existing conversations.
Adding a provider-supported model does not require another app update.

Android status now distinguishes configured chat from unavailable local tools.
API chat and session storage do not imply that file/Git, Agent or rish execution
has been implemented. Image capability declarations cannot add capabilities that
the provider or platform does not support.

## Build and verify the iOS local-substrate proof

The proof build links rish and libgit2 into a self-contained app and does not
depend on Metro or a Mac `dsh web` process. Both dependencies are packaged as
device + Simulator arm64 XCFrameworks.

Complete the [shared iOS preparation](#install-and-run-the-react-native-app)
above first, including `npm ci`, both framework preparation scripts, and
`pod install`. Then, from the repository root:

```sh
cd apps/mobile/ios
xcodebuild \
  -workspace Rish.xcworkspace \
  -scheme Rish \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath build/local-proof-arm64 \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build

xcrun simctl install <UDID> \
  build/local-proof-arm64/Build/Products/Release-iphonesimulator/Rish.app
cd ../../..
```

The separate unsigned `generic/platform=iOS` Release build is a required
device-link gate. It proves the iPhone arm64 slices link, but it is not evidence
that the app ran on a physical iPhone.

Confirm no Mac DSH listener is present, then import the key without putting the
value on the command line:

```sh
lsof -nP -iTCP:3180 -sTCP:LISTEN
./scripts/provision-simulator-key.rb \
  --secure-stdin <UDID> tech.zseven.rish
```

In the app, select **V4 Flash**, complete a real response, terminate and
relaunch the app, then verify the correlated record:

```sh
./scripts/verify-local-proof.rb <UDID> tech.zseven.rish
```

The verifier currently pins its acceptance request to V4 Flash. It checks the
actual container file and live Simulator process; a screenshot or an inherited
boolean is not sufficient evidence.

## Shared agent core (Rust)

`modules/rish/core` is a Cargo workspace (`rish-agent-core` for domain logic,
`rish-agent-ffi` for the C boundary) that will carry the Agent engine for both
platforms. The Objective-C++ engine under `modules/rish/ios/Sources` stays the
reference until each piece is migrated behind its existing interface.

Phase 0 ports the byte-level contracts every later piece depends on: canonical
JSON (`DSHWorkspaceCanonicalJSONData`), the domain-separated hashes
(`DSHAgentHJ`, `DSHAgentHB`) and the strict argument parser
(`DSHAgentParseArgumentsJSON`). Parity is pinned by a golden generated from the
Objective-C engine itself:

```sh
# 1. The XCTest writes the golden when this environment variable is exported
#    (an xcodebuild command-line argument does not reach the test process).
export TEST_RUNNER_RISH_CORE_GOLDEN_OUT="$PWD/modules/rish/core/fixtures/canonical-golden.json"
cd apps/mobile/ios
xcodebuild test -workspace Rish.xcworkspace -scheme Rish \
  -destination "platform=iOS Simulator,id=<simulator>" \
  -only-testing:RishTests/AgentCoreGoldenTests
unset TEST_RUNNER_RISH_CORE_GOLDEN_OUT

# 2. The Rust side replays the same corpus against that golden.
cd ../../../modules/rish/core
cargo test --workspace
```

Without the variable the XCTest runs in compare mode and fails when the
Objective-C output drifts from the committed golden. Add inputs to
`fixtures/canonical-corpus.json`, regenerate, and commit corpus and golden
together. The corpus `divergences` map lists the cases where the two sides
deliberately differ, with the stage responsible and the exact Rust output; the
Rust test asserts those too, so a divergence is pinned rather than skipped.

Phase 1 moves the schema-3 provider-round journal into the core as a pure
reducer (`crates/rish-agent-core/src/round_journal.rs`). The `…V3…` selectors
of `DSHAgentRoundJournal` are now a facade: they open the WAL transaction,
collect the round row, its dispatch marker, the bound transcript row and the
native-task liveness answers into a view, call `rish_agent_round_reduce`, and
apply the returned effect verbatim. Round policy (argument validation, CAS
matching, state transitions, transcript digests) lives only in Rust; the
provider catalogue answers a receipt needs (`DSHHarnessSupportedModels`,
`DSHHarnessIdForModel`, `DSHValidateProviderBinding`) are passed in as host
facts. The schema-2 selectors, which only two low-level tests used, were deleted
together with those tests.

Phase 2 does the same for the row-level half of the execution ledger
(`crates/rish-agent-core/src/execution_ledger.rs` for the row, precondition,
settled-fact, receipt and protected-feedback invariants;
`ledger_ops.rs` for insert, claim, heartbeat, CAS, mark dispatched, query,
release, settle, cancel, reconcile and the two in-state denial helpers). The
facade collects the row, the attempt's execution dispatch markers, the bound
transcript row, the attempt's reservation and batch records and the
task/attempt authorities as a view, calls `rish_agent_ledger_reduce`, and
applies the returned change list (each change names its table and, for
reservations, batches and authorities, the host-issued slot). Settlement also
returns the operation commit, which the facade performs through
`DSHAgentNativeWALCommitOperationInState` on the same candidate. Phase 3 moves the two production batch-level methods,
`prepareAgentToolBatch` and `openAgentWriteBatchEffectGate`, into
`ledger_batch.rs` with a wider view (the frozen round, the attempt's batches,
reservation, ledger rows and dispatch markers, the request's transcript row,
message-free summaries of every transcript, the round's denied calls, the
task/attempt authorities and operation results); approval-token UUIDs are
generated by the facade and passed in. `reserveWriteBytesForAttempt` and
`prepareAgentWriteBatch` had no production caller and were deleted together
with their tests, so the round journal and the execution ledger are now
Rust behind thin facades; `DSHAgentValidateRoundNativeEntryV2` and
`DSHAgentValidateExecutionLedgerEntryV2` stay in Objective-C because WAL
loading calls them.

Phase 4 moves `DSHAgentTranscriptStore` (create, validate, native message
reconstruction, append, mark terminal, discard, cleanup query) into
`transcript_store.rs`; the fresh transcript UUID and the retention
timestamp are generated by the facade and passed in, and the file-based
round presentation cache stays native because it is not authority.

Phase 5 moves the pure half of `DSHSessionSnapshotStore` into
`session_schema` (`scanner.rs`, `primitives.rs`, `validators.rs`,
`mod.rs`): the strict node-limited JSON scanner, the schema-9 candidate
validator with every sub-validator, the legacy (schema 2 to 8) root
validator, the v2/v3 envelope and tombstone validators and the
`chat-session` digest. The facade keeps file protection, pinned
descriptors, atomic writes, locks, the CAS decision and the validated
envelope cache; it hands the core the caller's exact bytes plus the host
facts the validators need (the supported models, harness ids and provider
hosts that occur in the tree, and the validity of every provider binding
in it) through `rish_agent_session_reduce`. The port is pinned to the
Objective-C validators by `fixtures/session-golden.json`, generated once
from `fixtures/session-corpus.json` before the native validators were
deleted: about 17,500 answers over the shared session fixtures, hand-written
legacy roots, envelopes, tombstones, lexical edge cases and a deterministic
mutation walk, replayed by `tests/session_schema.rs`. Three corpus inputs
made the native validator throw (a provider binding whose `endpoint_url` is
not a string) and are recorded as `!`; the core refuses them. The store's
CAS decisions follow in `session_schema/cas.rs`: request and authority
shapes, the replay-by-operation-id and expected-authority checks, the
tombstone-ledger rules, the next generation, the commit chain and the
canonical bytes of both files the host writes, the post-write verification,
`querySessionCommit`, and the clearance path's candidate, replay and
observed-operation rules. The host reads, locks, writes and reads back,
calling the core between those steps with what it observed.

Phase 6 moves `DSHAgentToolBatchService`'s decisions into `tool_batch.rs`
behind `rish_agent_tool_batch_reduce`: the prepare and bind request
shapes, the preparation gate, the per-call analysis of the round's raw
tool calls (identity against the round's presentation, registry access,
conversation grants, argument acceptance), the executor outcome mapping
with the whole-batch rejection cascade, the capability set, the final
authority check and the ledger's internal request, the ledger-failure
rejection, and the approval binding checks down to the result the WAL
commits. The host keeps the WAL operation relation, the committed session
load, the root proofs, the executors' preparation probes (run in call
order, stopping where the core would) and the denied-approval transaction.

Phase 7 does the same for `DSHAgentToolExecutionService` in
`tool_execution.rs` behind `rish_agent_tool_execution_reduce`: the request
shape, the committed-session relation, the pre-execution checks over the
WAL views (authority, batch, ledger row, prepared projection, approval or
grant binding, call ordering, row-state branching into replay, active,
unknown and ambiguous results), the ledger CAS, the settlement of an
executor's effect into receipt, tool message and patch, and the recovery
settlement. The host keeps the WAL operation relation, the session load,
the root proofs, liveness, the executors and the ledger calls.

Phase 8 moves `DSHAgentPreparedAttemptStore` into `prepared_attempt.rs`
behind `rish_agent_prepared_attempt_reduce`: the request shape, the
committed-session relation including the visible-history digest, the
observed safe values and the conflict result, the attempt projections,
and the prepare transaction itself (replay, not_agent, already_prepared,
prepared) as a change set the facade appends. The facade keeps the
session load, the root resolver, the tool registry, the workspace
authority guard held across the whole WAL transaction, and the
transaction itself; fresh transcript identities and clock readings are
passed in as host facts. `rish_agent_build_id` reports the linked core's
version and git revision so a test can prove which build it exercises.

The core links into the `RishLocalRuntime` pod as
`Vendor/rish_agent_core.xcframework`, built by
`scripts/prepare-rish-agent-core.sh` from the workspace toolchain
(`rust-toolchain.toml`) for `aarch64-apple-ios` and `aarch64-apple-ios-sim`;
the script refuses to install toolchains or targets itself. Rebuild it after
any change under `modules/rish/core` and before `pod install`.

Phase 9 moves the pure half of the provider round service —
`AgentProviderRoundServiceInternals.mm` — into `provider_round.rs` behind
`rish_agent_provider_round_reduce`: the round and selector request shapes,
the controller CAS and checkpoint relations, the transport result shape and
its relation to the request, the round locator and ledger CAS, the
native-to-provider message conversion, the public receipt, the recovered
round projection, the project-context bundle with its byte budget, the
failure-code mapping, the result projections, and the tool descriptions the
model is shown. The facade keeps the transport, credentials, the tool
registry's native descriptors, the root projection validator, the
completion transport's own schema validation, and the two provider digests.

Those digests are a second byte protocol and must not move: the model input
digest is `NSJSONSerialization` with `NSJSONWritingSortedKeys`, whose key
order is locale-sensitive, and the request body digest binds the exact bytes
that were sent. Both stay in `DSHProviderJSONSHA256` and reach the core as
host facts.

Phase 10 starts on the WAL itself, in the order the plan calls for: the
stored row shapes first, the transaction and resident state later.
`wal_state.rs` now owns what `AgentNativeWAL.mm` re-validated on every
load — transcript references and messages, reservations, cleanup rows,
dispatch markers, the frozen policy and tool registry, the attempt
authority with the exact tool set its root capabilities imply, and the
operation relation with its result references, safe results and result
snapshots (including each snapshot's own byte length and domain-separated
digest). The file, the descriptors, the locks and the transaction stay
native, and the loader reaches the core through
`rish_agent_wal_state_reduce`.

The second cut adds the rows those shapes are assembled into: the legacy
write batch and its schema-2 successor (read-only batches carry no manifest
at all, write batches must re-derive `manifest_sha256` from their own calls
and list exactly those calls' idempotency keys), tool receipts, denied and
rejected calls with their canonical feedback bytes, and the schema-3 round
row. The round row is the one place the boundary is crossed twice: the core
judges every V3 rule and returns the schema-2 projection, which the native
`DSHAgentValidateRoundNativeEntryV2` still has to accept before the row is
kept. The V1→V2 batch migration and the V2→V3 round migration move with
them, so an old file upgrades identically on both platforms.

The third cut moves the state-level validation itself: the root key lists for
both schemas, the per-attempt capacities, the transcript digests, the
authority and operation relations, the batch-to-reservation-to-ledger
agreement, the denied-call identities, and the dispatch bijection with the one
exception the WAL allows — a settled row with no dispatch is only ever a user
denial. Two typed validators stay native because the round journal and the
execution ledger still own them, so the loader computes one verdict per row
and passes them in as host facts; a ledger row the native validator refuses
comes back by index and is asked again, so the error the loader reports is
still the ledger validator's own. `AgentNativeWAL.mm` is down from 4,690 lines
to about 3,570.

Phase 11 moves the operation relation itself — start, query and commit, plus
the attempt authority, the write batch and the durable denial that share its
transaction. It is the first cut where the core decides a *transaction*
rather than judging a row, so it was recorded before it was moved:
`fixtures/wal-transaction-golden.json` holds 440 commands taken from the
native implementation by running the whole suite with its entry points
instrumented, each one a committed state, a command, the timestamps the clock
handed out, and the answer and committed rows that followed.
`crates/rish-agent-core/tests/wal_operations.rs` replays every one of them.
Like `session-golden.json` it cannot be regenerated: the native decisions it
records are gone.

The transaction stays where it was. `wal_operations.rs` is pure: it reads the
committed state and returns either a replay, an error, or the top-level
arrays to replace, and the host applies them only inside a transaction it has
written and confirmed. The commit is split in two halves so the in-state
variant can still let its fault hook refuse exactly where it used to — after
the relation has settled that this is a fresh commit and before anything is
written; the golden's faulted step asserts precisely that. The one deliberate
simplification is that the clock is now read once per command instead of only
on the paths that consume it. `AgentNativeWAL.mm` is down to about 2,840
lines, from 4,690 when phase 10 began.

Phase 12 starts on the coordinator, read-only half first. `runtime_coordinator.rs`
owns the controller-facing request shapes, the session proof every one of them
starts from, the tool and attempt projections, the merge of prepare-time
projections with persisted bind decisions and ledger settlements, and the
cleanup-outbox and cancel-source proofs the later cuts will need. The host
still loads the session snapshot and the WAL state and calls the typed
services; it passes the snapshot's generation and digest in as facts, because
only it can read them. Unlike phase 11 this cut writes nothing, so it rides on
the existing suites rather than a new golden — the recorded-golden treatment
is reserved for the cuts that settle transactions.

Phase 13 takes the settle path: finalize, discard and interrupt. All three
prove something and then rewrite WAL rows in one transaction, so all three were
recorded before they moved. `fixtures/runtime-coordinator-golden.json` holds 29
commands taken from the native coordinator with those entry points
instrumented: the committed WAL state, the request, the facts the typed stores
answered with, the timestamps the coordinator's own clock handed out, and the
answer and committed rows that followed.
`crates/rish-agent-core/tests/runtime_coordinator.rs` replays every one. Like
the other two goldens it cannot be regenerated.

The core returns the arrays to replace plus the arguments for the WAL
operation commit, which the host still makes itself, so the WAL's fault hook
keeps speaking where it always did. A refused finalize is not a failed call:
it commits its own conflict as the operation's result, and the golden holds
that case too.

Phase 14 takes cancellation: the target request shape both target commands
share, the conflict shape that names what the controller expected beside what
the session says, the plan that decides whether a cancellation addresses a
tool row, a round, an attempt that never launched one, or nothing the WAL
knows, every result projection, and the reference each of the two commit
mappings points its operation result at. The effects stay native — the round
journal cancels the round, the ledger moves the row, the execution service
interrupts an in-flight git_push — and the host still reads its own dispatch
marker, because only it knows whether an execution was handed out. Cancel
rewrites no WAL rows itself, so it rides on the existing suites; the rows it
moves are written by services that are already ported and already locked.

Recovery's own shapes move with it: its request validation, the conflict it
reports (including the one case that reports a newer journal revision learned
from its own attempt query rather than the session proof's), and the reference
its operation result points at. What is left native in
`recoverAgentAttempt` is the orchestration itself — in particular the provider
retry continuation, the one step that leaves the serialized recovery authority
and re-enters. That is the `Command → Effect → Event` refactor the plan
describes, and phase 15 does it.

`runtime_coordinator.rs` now owns recovery's decisions as well: the status and
next action each round outcome implies, whether a retry may proceed and which
launch attempt it gets, the relaunch request built from the authority's own
facts, what the relaunched round concluded, the tool branch's plan (the ledger
row, the batch and the prepare-time call that together name the execution),
the child operation's commit, and the result every branch ends with. What
stays native is the shape of the orchestration: the service calls, the
serialized recovery authority, and the one continuation that leaves it to run
the provider retry and re-enters when the answer arrives. The coordinator is
down to 1,212 lines from 2,412.

Phase 16 finishes the provider round service's own answers: the reference and
result a round operation's commit points at, the public outcome a completed
round hands the controller (final, tool_batch or blocked), and the failure code
each row state implies for a query, for a round whose writer has provably
released it, for one reconciled after that writer died, and for one just
cancelled. What stays native is what the plan always said stays: the
transport, the streaming parser, the preview publisher, the credentials, and
the round context a cancellation has to reach into.

### One set of session rules on both platforms

Android used to decide session persistence itself. Its CAS keyed replay on the
whole request's bytes and threw when an operation id came back with different
ones, stored conflicts as durable receipts, and accepted any candidate that
merely said `schema_version: 9`. None of that is what the shared rules say, so
a session written by one platform was not necessarily a session the other
would accept or replay the same way.

`scripts/prepare-rish-agent-core-android.sh` now builds the same core for
`aarch64-linux-android` and stages it beside the guest runtime, and
`src/main/cpp/rish/rish_agent_core_jni.cpp` exposes the session reducer over JNI.
`AndroidSessionStore` keeps SQLite as the storage mechanism and nothing else:
the request shape, the candidate's acceptance and digest, the replay and
expected-authority checks, and what a query may conclude all come from the
core. Three differences are gone with it — replay is keyed on the candidate,
so the same session in different bytes is the same commit; a conflict is no
longer written down, so an operation may be retried once its author has
re-read the authority; and a candidate is judged by the whole schema-9
acceptance graph.

Android still refuses candidates that carry native authority, because it
issues none: that is a platform policy stated on top of the shared rules, not
a second reading of them. The catalogue the core needs — which strings name a
supported model, and which harness each belongs to — is collected from the
candidate itself, exactly as `DSHSessionCoreEnvironment` does on iOS.

### The frozen assets

Six assets under `modules/rish/core/fixtures` were recorded from native
implementations that have since been deleted, so none of them can be
regenerated: the canonical-JSON corpus and golden, the session corpus and
golden, the WAL transaction golden and the runtime-coordinator golden.
`fixtures/FROZEN.md` pins each one's digest beside the commit it was recorded
at and what it locks, and `scripts/verify-agent-core-fixtures.sh` checks them.
The repository's Actions are disabled, so nothing else will — run it before
trusting a green core suite.

A test that disagrees with one of these is either a real behaviour change,
which belongs in a new fixture beside them, or a porting mistake. Editing one
to make a test pass destroys the only evidence that the port was faithful. The
mutation walk that expands the session corpus into its golden is part of the
same contract for the same reason.

### The WAL's resident state

The core now holds each storage root's committed state behind an opaque handle
(`wal_resident.rs`), so a transaction that already knows what is committed does
not re-read and re-parse the file to find out. The host still owns the file,
the lock and the write; what moved is who remembers.

The contract is the three-state confirmation the plan calls for, and the rule
it exists to keep: **a write that failed is not a write that did not happen.**
`writeStateLocked:` now reports which of the three it ended in — provably not
committed before the rename, durable after the directory fsync, and unknown in
between. A committed confirmation publishes the candidate; a not-committed one
discards it and leaves the handle usable; an unknown one neither publishes nor
discards, because which of those is true is exactly what is not known. It
invalidates the handle instead, and the next transaction reads the file again.

Two rules keep the cache sound. The handle belongs to the root rather than to
an instance, because several `DSHAgentNativeWAL` objects can address one root
and there must never be two owners of one state. And it is trusted only while
the file it was read from is still the file on disk — device, inode, size and
mtime are compared before every use — so a fixture, a restore or any future
tool that replaces the WAL behind the store's back is seen rather than served
from memory. `testCommittedStateIsRereadWhenTheFileIsReplacedBehindTheStore`
is that case, and it fails without the identity check.

### The WAL on Android

The Android WAL writes the same bytes: `agent-native-wal-v1.json` under the
app's no-backup directory, the whole state as canonical JSON, replaced by
write-temp, fsync, rename, fsync-directory. The format is shared on purpose —
every rule about what a stored state may look like already lives in the core,
and a WAL pulled off a device replays through the same harness whichever
platform wrote it. SQLite would have meant a second storage adapter and a
second answer to "what is committed", which is exactly what the session store
just stopped having.

`android.system.Os` can fsync a directory from Kotlin, so the only JNI needed
is the reducer bridge that already exists. The three-state confirmation is the
same as iOS: everything before the rename is provably not committed, the
directory fsync makes it durable, and a failure in between is unknown and
refuses rather than guessing.

Two Android-specific hazards are covered by tests because both were real bugs
first. The resident state must not answer while a staging file is present —
a torn transaction is exactly the hazard a cache would hide, so the check runs
before the cache, not after. And every native call has to load the library
first: the reducers did it through their own guard, the handle calls did not,
and the WAL reached them on a path that had never loaded anything.

`AgentRuntimeModule` is still a stub. This is the storage layer it will stand
on, not the engine.

The transcript store follows it, as a facade over the same reducer iOS calls:
the host owns the WAL transaction, generates the fresh transcript id and the
retention timestamp, collects the view, and applies the returned changes
verbatim. The round-presentation file cache iOS keeps is display only, not
authority, and is not mirrored.

Writing the Android facade is also the first time the shared rules have been
read by someone who did not write the iOS one, and that found three things
the iOS call sites had simply always got right: a transcript holds assistant
and tool turns only, because user text lives in the session; `append` and
`mark_terminal` name the row they expect to still be there through
`expected_transcript`, not `transcript`; and a root is the full seven-field
form, not a path. Each of those is now a test.

The round journal and the execution ledger follow, on the same facade shape:
collect the view, call the reducer, apply the row, dispatch-marker and
transcript effects it returns, and answer whether an owner is still alive in
this process. Between them they turned up the mistake that would have been
hardest to find from the outside: **`org.json.JSONObject` has no value
equality**. Every "is this the row the locator names" comparison used `==`,
which compares references, so a lookup simply never matched and the journal
inserted a second row and a second dispatch marker instead of reporting
already-present. `AndroidJson.equal` is the structural comparison those call
sites now use; the state-level validation caught the duplicate marker, which is
exactly what it is for.

Three more shape facts the iOS call sites had always got right: a round locator
is schema 1 while a round CAS is schema 2, an owner carries its own `task_id`
and `heartbeat_at`, and `claim`/`mark_dispatched` take a full CAS rather than a
revision.

### The tool table is a table

`AgentToolRegistry.mm` held the frozen tool descriptors, the access each root
capability implies, the write policy and the toolset digest. The table is a
pure table and the digest taken over it is what every stored authority is
bound to, so a second copy on Android would have been a second source of
truth for a compatibility contract. `tool_registry.rs` owns it now, and both
platforms read it.

One thing does stay with the host, because the core cannot know it: whether
this build has the guest CGI tools compiled in. iOS answers from
`DSH_GUEST_CGI_AVAILABLE`, Android answers no, and the digest follows. Both
values are pinned in the core's tests — a change to the table changes them and
invalidates every authority on every device, which is exactly the kind of
change that should be hard to make by accident.

### The approval preview's bounds, pinned

The preview is what a person reads before approving a write, so what its bounds
**hide** is as much the rule as what they show. Seven cases are now pinned
against `DSHAgentApprovalUnifiedDiff` as it stood at `8e33d06`, the last commit
before it moved into the core:

- the hunk header names where the change starts, one-based, and counts the
  whole change rather than the part shown;
- three unchanged lines of context either side, both taken from the prior;
- at most 24 lines each way, with `…` between the added lines and the trailing
  context; exactly 24 is not truncation;
- **past 2,000 lines both sides are cut before anything is compared**, so a
  change below that line is not elided from the hunk — it is never seen, and
  the truncation flag is the only thing that says so. That is why the flag may
  only ever be raised;
- over 4,096 bytes the preview is cut to half the budget on a character
  boundary, with `…` appended;
- an insertion or deletion anchors on what did not move rather than reporting
  the whole file;
- a file ending in a newline has a trailing empty line, which anchors the
  suffix and is then emitted as a context line that renders as a lone space.
  Odd-looking, and exactly what the original did.

Both bounds were verified load-bearing by widening them and watching the
assertions fail.

### What a person is told the agent may do

`AgentPolicyService`'s describe result is a *safe projection*: it is handed to
the JavaScript layer and shown in the UI, so the interesting property is not
what it contains but what it must never contain — a filesystem path, the native
descriptor table, tool arguments, or anything that could be mistaken for an
authority handle. `agent_policy.rs` enumerates its keys rather than copying
them from the inputs, and a test feeds it a registry carrying an absolute path,
a parameter schema, an arguments string and the toolset digest, then asserts
none of them reach the output.

Three rules moved with it:

- the request shape (exact keys, canonical workspace id, a binding revision
  that starts at 1);
- the budget shape, including the invariant the three bounds **nest** —
  a single write cannot exceed what a batch may spend, and a batch cannot
  exceed what an attempt may;
- the agreement check between the resolved root and the request. A resolver
  that answered for a different workspace, revision or project answered a
  different question, and the display would be about something else.

The root fingerprint stays in the projection on purpose: it lets a UI notice
that a grant display has gone stale. It grants no execution authority.

### What of a repository may be sent to a model

`chat-read-v1`'s path policy — which directory, filename or extension is a
secret, generated output, a lockfile or a binary, and the order those are
consulted in — is now `project_context_policy.rs`. It is the highest-stakes
table in the engine: a path that stops being recognised as sensitive is a
secret sent to a provider, not a formatting difference, so there is one copy of
it.

**Case folding stays with the host.** Foundation folds with
`CFStringFold(kCFCompareCaseInsensitive)`, which is Unicode case *folding* and
not lowercasing; Rust's `to_lowercase` is a different operation and the core
carries no folding table. So `ProjectContextPolicy.mm` folds exactly as it
always did and passes the folded spellings across — the same shape as the
`foundation-json-v1` projection. Foundation's `pathExtension` and
`stringByDeletingPathExtension` travel with them, applied to the folded
spelling, because their edge cases (`a.`, `.hidden`, `a.b.c`) are Foundation's
too. Nothing about *which* folded names are sensitive stays behind.

Two properties worth naming because a port loses them quietly:

- **The reason is the first one met walking the path from the root**, not the
  most serious one on it. `node_modules/.ssh/id_rsa` is omitted as *generated*,
  because the walk stops at `node_modules`. Within a single component, secret
  is tested before generated.
- **The length bound is decided on the reported length alone, before a single
  character is read.** Normalizing first would do work proportional to a
  hostile input that is about to be refused. That check stays on the host side
  of the call; the core bounds the path too, but by then the copy has happened.

`decisionForContentData:` moved with it. Its order is the rule — a file over
budget is refused before its bytes are looked at, a NUL makes it binary before
it is decoded, and only then does encoding matter — and one Foundation detail
had to be reproduced rather than tidied up: the control scan walks **UTF-16
code units**, because `characterIsMember:` takes a `unichar`. A format
character outside the BMP arrives as two surrogates, neither of which is a
control character, so it passes. Writing that scan over code *points* in Rust
would have made the core stricter than the rule it was replacing.

The second one was a regression this cut introduced and
`testPublicStringInputsAreBoundedBeforeNormalization` caught it — it hands the
policy a string that reports a length of a megabyte and throws if anything
reads it. That suite's 31 tests were written against the original
implementation, which is what makes them parity evidence rather than a port
agreeing with itself.

### Pinning a port against the implementation it replaced

Four of the migrations in this document shipped fidelity regressions that the
full simulator suite could not catch, because the edges they changed were not
covered by any existing test: Foundation's whitespace set includes U+200B and
Rust's does not; Foundation's JSON writer spells slashes differently from the
core's canonical form, and the escaped bytes count against an argument limit; a
non-UTF-8 staged Git path answered `E_AGENT_CONFLICT` and started answering
`E_AGENT_CORRUPT`; and a directory walk that used to stat lazily started
statting every entry, so a `.staging-*` file removed between `readdir` and
`stat` turned a listing into a conflict.

Every one of those cuts reported "the same pre-existing failures, none new."
That was true and it was not enough. **A green suite proves no *covered*
behaviour changed.** For a port whose whole claim is that behaviour did not
change, the evidence has to be a test that pins the old rule.

`AgentRootProjectionTests` is what that looks like when the old implementation
is already gone: every expectation in it is read off `DSHAgentRootProjectionShape`
and `DSHAgentRootCapabilityArray` **as they stood at 65fa32f**, not off the Rust
that replaced them — the seven exact keys, schema version exactly one, a binding
revision that starts at 1, canonical identifier spelling, a capability list that
is bounded at six and free of repeats, and a workspace root that may not name a
Git capability. It was verified load-bearing by disabling the workspace/Git rule
in `schema::root_full` and watching three assertions fail.

When the old implementation still exists, prefer the stronger form: run both
against the same inputs and assert identical output, as
`CompletionResponseParityTests` does.

### Resolving a root is a capability; judging one is a rule

`AgentRootResolver.mm` does two different things in one file. It resolves a
root — reads the workspace registry, checks the binding revision, takes the
workspace and project leases, holds the authority mutation guard, talks to
libgit2 — and that is host capability: nothing about it can be shared, because
the two platforms do not have the same storage. But along the way it makes
judgements, and those are rules: what a resolver argument may look like, which
capabilities a set of workspace grants implies, how a workspace root is
promoted to a project root, which capability an operation mode needs, and
whether a final-proof request asks for the leases its capabilities will use.

`root_projection.rs` owns the judgements (`rish_agent_root_reduce`); the
resolver keeps the capability and calls into the core for every decision. The
projection shape is not a new rule there — it is `schema::root_full`, the same
one the round journal and the execution ledger already validate stored roots
with, so the resolver and the stores can no longer disagree about what a root
is.

The sharpest case is the capability derivation and its inverse. One direction
turns the host's grants (`read`, `write`, `git`) into Agent capabilities when a
root is built; the other turns Agent capabilities back into the grants a lease
must require before the root is used. They are read by different call sites and
they must be exact inverses — a grant lost on the way back means a capability
exercised under a lease that was never taken for it. The core holds both and a
test round-trips all eight grant sets.

`guest_service` is the one capability that is not a rename of a grant: it needs
both file grants *and* a build with the guest CGI tools, so the host says
whether this binary has them, exactly as it does for the toolset digest.

Two consequences worth knowing. Promotion to a project root is idempotent — the
three Git capabilities are appended once, in their canonical order — because
the guarded validator re-derives an expectation from a base it may already
hold. And a root that cannot serve an operation is `E_AGENT_CONFLICT`, not
`E_AGENT_INVALID`: the request was well formed, the root simply does not carry
the capability.

Android does not call this reducer yet, and cannot: `LocalWorkspaceModule` and
`LocalProjectsModule` there are stubs that reject every method. Resolving a
root needs a workspace subsystem and a project subsystem, neither of which
exists on Android; that is product surface, not engine migration. The rules are
in place for when it does.

### The write-approval preview

The preview a person approves before an agent writes a file is built in
`AgentWorkspaceToolExecutor.mm`. Three of its bounds interact and two of them
were wrong.

The byte budget is 4,096 **UTF-8 bytes**, but the clip that enforced it used
`-substringToIndex:`, which takes a **UTF-16** index. For CJK text the two
differ by a factor of three: 1,500 Chinese characters are 4,500 UTF-8 bytes —
over the budget, so the clip runs — but only 1,500 UTF-16 units, so clipping at
index 2,048 raised `NSRangeException`. That is a hard crash on the approval
path, reachable by any sufficiently large edit to a Chinese-language file. The
clip now uses `-getBytes:maxLength:usedLength:…`, which stops on a character
boundary and never splits a multi-byte sequence.

The truncation flag was cleared on entry to the diff helper and assigned again
on the way out, so each bound could erase the one before it. In particular a
file longer than the 2,000-line diff bound with a small edit inside that bound
was presented as a *complete* preview: anything past line 2,000 was approved
unseen. The flag is now only ever raised, never cleared.

The third case — a prior read cut off at 64 KiB — is not reachable today,
because a single write is capped at 32 KiB, so a truncated prior always
produces a hunk or a byte clip that raises the flag anyway. The helper no
longer depends on that coincidence.

Both reachable cases have tests in `AgentToolEffectsTests` that fail against
the old helper, the first with the `NSRangeException` itself.

Nothing recomputes a stored preview and compares it, so this is not a
compatibility change: an old receipt keeps the text it was written with, and
the preview's shape is unchanged.

### The completion failure vocabulary

Which failure a completion round may report is a closed set of 33 codes, and
the controller switches on them to decide whether a retry could possibly help.
They were scattered as string literals across the transports; `FAILURE_CODES`
in `completion_response.rs` is now the list, with the two rules that pick from
it:

- **`http_status_failure_code`** — 401/403 mean the stored credential is
  unusable, 429/529 get their own code so a caller backs off rather than
  retrying as a generic status failure, everything else is a plain status
  failure.
- **`parser_failure_code`** — fail-closed. A parser refusal may only name one
  of the eight parse codes; a verbose diagnostic, a third-party `NSError`, or a
  store code becomes `E_COMPLETION_EMPTY_RESPONSE` rather than travelling
  onward as something the controller would switch on.

What stays in the transports is the capability: `NSURLSession`, streaming,
redirect handling, credential generation, timeouts and the diagnostics.

`DSHCompletionNormalizeToolCalls` was going to move with them and did not, for
a reason worth recording. It re-serialises normalised arguments with
`NSJSONWritingSortedKeys`, and Foundation's sorted-key output is **not** the
core's canonical JSON — which is exactly the fidelity gap the
`foundation-json-v1` projection exists to close, by asking the host to do the
encoding. Moving the second pass would mean running that projection for a
belt-and-braces normalisation the parser has already applied. Not worth the
machinery; it stays with the host.

A note on how the first version of this cut failed, because the failure mode is
easy to repeat. The new ops were added to the reducer *below* its
`op != "parse"` early return, so every one of them answered "not JSON" and both
mappings silently fell back to their default code. Nothing in the core noticed —
its tests called the functions directly — and the iOS suite went from 9 failures
to 25. `the_reducer_answers_every_op_it_claims_to` now drives every op through
`reduce_json` itself and fails against that bug. **A reducer needs a test that
goes through the reducer**, not only through the functions behind it.

### What a stored workspace record looks like

`workspace_record.rs` is the third workspace rule, after the fingerprint and
the grants: it is the record those two are computed over.

**The origin fixes everything else.** A record does not get to name a locator
kind, a location class, an owned directory and a legacy project independently —
each origin fixes all four, and a record that mixes them is not a record. A
documents-owned origin has a directory name and no legacy project; a granted
folder has neither; a legacy origin has a project and no directory.

Two rules worth naming:

- **A capability array has one spelling.** At most four, each known, no
  repeats, in the fixed order — so a stored record digests the same everywhere,
  which matters because the fingerprint covers it.
- **A binding revision advances by exactly one.** A gap would let two rebinds
  look like one, and a repeat would let a stale authority pass as current.
  Running out of safe integers is its own answer, not a conflict: at the top of
  the range that binding can never be rebound again.

Case-and-diacritic folding stays with the host. Foundation folds both together
under `en_US_POSIX` — neither lowercasing nor the case folding the
project-context policy uses — and the reserved-name check (`rish workspaces`,
the `.rish-` prefix) is on the folded spelling so case and diacritics cannot
dodge it. A host that could not fold refuses rather than guessing.

### Android resolves a root

`AndroidAgentRootResolver.kt` turns a workspace binding into the root an agent
attempt runs against, and `AndroidPreparedAttemptStore` now prepares one for
real instead of refusing every rooted request.

**What an Android workspace root can do: read and write files.** The registry
grants read, write and git, but the shared rule only turns `git` into Agent Git
capabilities for a *project* root, and there is no project subsystem here;
`guest_service` needs the guest CGI tools, which this build does not ship. So
the projection is exactly `["file_read", "file_write"]`, and the test pins that
rather than asserting something vaguer.

**A project root is refused, not approximated.** A project root needs an
independently verified lease. Answering a project request with a workspace root
wearing a project's name would hand the caller authority it never established.

**The session store now accepts workspace-bound conversations.** It used to
refuse `workspace_id` and `workspace_binding` outright, which made the
root-stale branch unreachable — the request and the stored attempt always
disagreed first, so a test that looked like it covered rooted requests covered
nothing of the sort. `project_id` and `project_context` stay refused. Whether a
binding can still be *proved* is decided where it is used: a session records
what the person chose, the resolver decides what that is still worth.

`aRootedAttemptResolvesItsWorkspaceAndPreparesForReal` is the first prepared
attempt on this platform that is not a rejection — an authority and a
transcript, against a root whose fingerprint is the registry's. Checked by
mutation: dropping the resolved root from the transaction fails one test, and
restoring the session store's old refusal fails four.

### Android's workspace registry

`AndroidWorkspaceRegistry.kt` is the first workspace subsystem on Android. It
writes the same record, authority and fingerprint iOS writes, validated by the
same shared rules, so growing it later is new code over the same bytes rather
than a migration.

**Scope, and why.** Only the `rish_created` origin can exist on Android: there
are no security-scoped bookmarks and no legacy iOS projects, so those two
shapes are unreachable and are rejected rather than stubbed. There is no
rebinding either — an app-private directory keeps its identity for as long as
the app is installed, and the one event that changes it takes the data with it
— so every record is at binding revision 1 and nothing there exercises
`binding_revision_advance`.

**Folding is per-host and that is fine.** iOS folds with Foundation under
`en_US_POSIX`; Android uses NFD with combining marks dropped, lowercased in the
root locale. The two do not always agree. A folded name is never stored, only
compared against other names on the same device; everything that *is* stored
goes through the shared rules.

**Inode reuse.** `aReplacedDirectoryIsNotTheSameRoot` originally deleted the
directory and recreated it — and passed the old identity straight back, because
the freed inode is handed out again immediately. The test now moves the
directory instead, which keeps the old inode allocated, and asserts that the
replacement really did get a different one so it cannot quietly stop testing.
Worth naming as a limit of the design: physical identity catches a folder
swapped for a *different* one, not a folder deleted and rebuilt in its place.
Neither platform claims otherwise.

The twelve instrumentation tests were checked by breaking three rules: not
asking whether the record is the right shape, not comparing the directory
identity, and inventing the fingerprint instead of asking for it. The last one
fails nine of the twelve.

### Android operations are idempotent now

`AndroidWorkspaceRegistry` had no notion of an operation id: a retry after a
crash created a *second* workspace where the person asked for one. It has a
receipt store now, on the rules `workspace_receipt` already held and which
nothing on Android exercised.

`create` takes an operation id, replays the receipt if one exists, and writes
one last — **after** the registry. A crash before the receipt leaves an
unreceipted workspace rather than a receipt for one that is not there; the
retry then finds no receipt and refuses on the directory that already exists,
which is a visible failure instead of a silent second workspace.

**A receipt binds the operation to its request.** The same id with a different
display name is a different operation reusing an id, and it is refused rather
than answered with somebody else's workspace.

`queryOperation` returns the public projection, which withholds
`request_sha256` — the same rule iOS follows, for the same reason.

### What a project-context result may say

`project_context_bridge.rs` ports `DSHPCSafeRelativePath` and
`DSHPCBoundedString` from `LocalProjectContextModule.mm`. The identifier,
digest and OID rules that file also carried are `project_module`'s, and are
re-used rather than restated.

**This path rule is not `execution_ledger::relative_path_argument`**, and the
two are deliberately kept apart. That one bounds an agent's tool *argument* at
512 bytes and demands NFC; this one bounds a *reported* path at 4096 and does
not, because it describes a file that already exists rather than naming one to
act on. It also refuses a `.` component, which the other allows.
`it_is_not_the_agents_tool_argument_rule` pins three inputs where they
disagree, so merging them later is a decision rather than an accident.

### The iOS baseline, stated properly

After the container-anchor fix, the persistent failures are **five**:
`LegacyBoundProjectRootAccessTests
testVerifiedLegacyRootRunsFileWriteStatusAndCommitEndToEnd` and four
`RuntimeEnvironmentStoreTests`. Three UI tests —
`DeviceCloneDriveUITests` twice over and `HarnessEvidenceUITests` — fail on
some runs and pass on others; a run where all three passed has been observed.

Three further one-off failures were seen across this work and each passed 3/3
in isolation and did not reproduce on a second full run:
`AgentProviderRoundServiceTests testSynchronousBoundTaskReturnedByTransportIsNotCancelled`,
`CompletionV2StreamTests testCancelBeforeTaskBindDoesNotPoisonTheCompletionSlot`
and `CompletionV2Tests testSchema1RedirectStillFollowsAndCompletes`. All three
are in async transport paths and none is touched by this work. **Counting them
as "pre-existing failures" would be wrong in both directions** — they are
neither stable nor caused here.

### The six readers a workspace exposes

`workspace_read_tools.rs` ports `LWToolNameValid`, `LWToolOptionsValid` and the
output bound from `LocalWorkspaceModule.mm`.

**The tool list is closed, and that is the point.** These run against a folder
a person granted, so the surface is six named readers — `cat`, `grep`, `head`,
`tail`, `wc`, `sha256sum` — and nothing else. Not "any command", not a string
that happens to start with one of them.

**An unknown option key is refused, not ignored.** Ignoring it would run a
different command than the caller asked for and report success. Each of the
four keys has its own shape: a positive line count within 1000, one of three
metrics, a non-empty pattern under 1 KiB, and a real boolean — `1` is not a
boolean here.

The same commit removed the **third** copy of the workspace error table, which
`LocalWorkspaceModule.mm` carried after `LocalWorkspaceAccess.mm` and the core.
It asks `workspace_error` now. An error that already carries a public code
keeps it: it came from a layer that had already made the decision.

### Which project failure JavaScript is told about

`project_module.rs` ports `LPV2StableErrorCode`, `LPV2CanonicalOID`,
`LPV2CanonicalOperationId`, `LPV2BoundedString` and `LPV2ClipUTF8` from
`LocalProjectsModule.mm`, which had no core calls at all.

**The stable code is the contract.** JavaScript branches on it, so the mapping
from an internal failure in one of three domains to an `E_…` string is a rule
both platforms answer alike. An unrecognised failure becomes
`E_PROJECT_NATIVE`, not a guess: a caller must not be able to branch on a
failure that does not exist.

**The workspace half re-uses `workspace_error`** rather than keeping a second
spelling of the same codes — they were two tables with the same contents, one
edit from disagreeing. One deliberate difference remains and is tested: a busy
picker is reported to a project operation as plain `E_WORKSPACE_BUSY`, because
a project operation has nothing to say about the picker.

`clip_utf8` backs off to a character boundary. Taking the byte bound literally
would cut a multi-byte character in half and produce a string no consumer could
read; the test checks the result is always a prefix of the input across every
bound from 0 to 12.

An **operation id** may be the nil UUID, unlike a snapshot id — it is the
caller's to choose and nothing reads a sentinel out of it. The test asserts
both, side by side, so the difference reads as intended rather than as an
inconsistency.

### How a context snapshot is named

`project_context_service.rs` ports `DSHServiceV2ReferenceId`,
`DSHServiceV2RootsEqual`, `DSHServiceV2BoundedString` and
`DSHServiceCanonicalDigest`. The root reference rule is **not** re-stated: this
file carried a second copy of the one `project_access` owns, and now asks for
it.

**The reference id is derived, not chosen.** `ProjectContextStore` names a
prepare transaction by the suffix of an `active:<uuid>` key, so if that uuid
were the conversation's, two workspaces using one conversation id could evict
or authorise one another's snapshot. It is a digest over the whole authority
tuple — root, root fingerprint, conversation — shaped into a UUID with the
version and variant bits set, because the store checks it is a canonical id.

**A round trip is not a parity test, and this is the proof.** While a core
built with a changed derivation domain was staged, all 106
`ProjectContextWorkspaceV2Tests` passed: a round trip writes and reads with
whatever derivation it has, so self-consistency survives any change to it. Only
an already-stored snapshot would notice — and there are none in a fresh test.

`testReferenceIdMatchesTheOriginalDerivation` is the real check: the original
ObjC algorithm, transcribed and running against Foundation and CommonCrypto as
it did, against the core, over twelve tuples. It failed on all twelve against
that mutated core, which is how it is known to be load-bearing rather than
assumed.

**And the reason that mutated core was still staged is worth recording too.**
Restoring the Rust source is not enough: `prepare-rish-agent-core.sh` has to
run again, or the linked xcframework is the old one. The first parity run
reported a mismatch that did not exist. Same trap as a stale `.app`, one layer
down.

### What an interrupted context swap resolves to

`project_context_store.rs` ports the store's naming rules and its recovery
sweep from `ProjectContextStore.mm`.

**A reference is a name pointing at a snapshot**, in three namespaces:
`active:<conversation>` (what a conversation is using), `retry:<…>` (held so a
retry can reuse it, and the **only** kind a caller may set), and
`txn:prepare:<conversation>` (written before `active:` is swapped, holding the
id to go back to). A caller that could write `active:` could point a
conversation at a snapshot of its choosing.

A `txn:prepare:` key still present at launch means the process died mid-swap.
**The subtle case is `crash_before_swap`:** when `active:` still holds the id
the transaction recorded, the swap never happened, so there is nothing to undo
and the new snapshot is *not* collected. Undoing there would throw away the
snapshot the conversation is actually using.

The sentinel `00000000-…-000000000000` means "there was no prior snapshot". It
is deliberately not a valid snapshot id: rolling back to it would point a
conversation at something that never existed.

**Three checks inside the loop are redundant with the sweep that follows**, and
the mutation test says so rather than leaving them looking proven: refusing to
roll back to the sentinel, refusing to roll back to an id that is gone, and
removing the transaction key. In each case the sweep drops the same key a
moment later, so no input the host can produce tells them apart. They stay
because they mirror the original line for line and because the sweep is a
separate rule that could change — `the_sweep_is_what_actually_drops_them` pins
why, so anyone loosening the sweep knows those three stop being redundant.

### Where the app's own container ends

`container_anchor.rs` ports `DSHIsCanonicalUUIDText`,
`DSHComponentsEndWithAppContainer`, `DSHLastAppContainerComponentIndex`,
`DSHComponentsContainTraversal`, `DSHContainerAnchorSegmentCountForPaths` and
`DSHContainerRootScanSegmentCount`.

**This rule exists because guessing path shape got it wrong on real devices.**
The walker used to scan for an `Application` component followed by
`Application Support`, which never matches
`/private/var/mobile/Containers/Data/Application/<UUID>/…`, so it fell back to
opening `/private/var` — which the sandbox refuses with EPERM. The anchor is
derived from the container root instead.

**The innermost `Containers/Data/Application/<UUID>` wins.** A container root
must also *end* at its own UUID: one carrying anything after it is not a
container root, and anchoring there would let the caller choose where the walk
starts. Traversal is refused at derivation time as well as during the walk, so
an anchor is never derived from a traversal-shaped path.

Splitting a path stays with the host: `pathComponents` is Foundation's and
keeps a leading `"/"` a naive split would not.

**A test whose name described something it did not test.** The first version of
`the_innermost_container_wins` used the simulator layout — but the CoreSimulator
device UUID there is not preceded by the container tail, so there is only *one*
candidate and scanning from either end gives the same answer. Reversing the
search left every test green. It now uses a path with two real container tails,
and the mutation fails.

**And one of the nine pre-existing iOS failures was a test defect, now fixed.**
`ContainerAnchorTests testSimulatorShapePathAnchorsAtAppContainerRoot` asserted
the literal index 12, derived from a shallower `NSHomeDirectory()` than this
machine has; here the answer is 22. The expectation is computed from the
container root now, which is what the anchor is supposed to make unnecessary.
The baseline is eight failures, not nine.

### What a project binding is

`project_access.rs` is the first cut into the project subsystem, the peer of
the workspace subsystem: a workspace is a folder someone granted, a project is
a Git working tree inside one. It ports `DSHLocalProjectRootRefIsValid`,
`DSHLocalProjectCanonicalRootRef`, `DSHLocalProjectBindingIsValid`,
`DSHLocalProjectBindingDigest`, `DSHValidStoredMetadataRecord` and
`DSHLocalProjectCanonicalLegacyDisplayName` from `LocalProjectAccess.mm`,
which had no core calls at all.

**A binding restates the root reference's identity and the root fingerprint.**
That is its job: one found beside a project has to prove it was written for
*this* root at *this* revision, or it is a binding for something else that
happens to be in the way.

**The git directory path is not in the binding's digest.** It is a local fact
that differs between installs of the same project, and folding it in would make
two devices disagree about a binding they agree about. It also cannot cross as
an `NSURL`, so the host hands over its path and whether it was a file URL at
all — a projection, like the others.

Stored project metadata's timestamps are **bounded, not parsed**. The record
predates the canonical timestamp rule, and refusing an old project over its
date format would lose the project rather than fix the date. Said here so the
looseness reads as a decision.

**A projection that is not load-bearing, said out loud.** Foundation's
`whitespaceAndNewlineCharacterSet` includes U+200B where Rust's `trim` does
not, so the legacy display name's trimming is handed across. It changes nothing
these tests can reach: U+200B is a format character, and
`path_control_or_format` already refuses it — replacing the host's answer with
`name.trim()` leaves every test green. The projection stays because
Foundation's set cannot be enumerated from this side and being wrong about it
would mean accepting a padded name the writing device refuses. A guard against
an unknown, held deliberately rather than by accident.

### What a destructive workspace operation needs before it runs

`workspace_clearance.rs` ports `DSHWorkspaceClearanceCanonicalOperationFields`,
`DSHWorkspaceClearanceReceiptFields` and
`DSHWorkspaceClearanceSessionReferenceValid`.

A clearance is the proof that a destructive operation — forget, or delete the
owned content — was authorised against **a specific committed session**. That
is why the receipt names the session's generation and digest: without them,
"they said yes" could mean yes to a different state. `receipt_authorises` is
new rather than ported; it states in one place what the store checked in
several: the receipt id, the operation id, the workspace and the binding
revision must all agree. A receipt for the right workspace at the wrong binding
is consent for a root that has since been rebound.

A session generation counts from one. Generation zero means no session has ever
been committed, which nobody can have agreed to.

**The clearance store's bounds are the workspace receipt store's bounds** —
2048 receipts, thirty days — and they are now re-exported from
`workspace_receipt` rather than written out again. They were already the same
numbers in two files; two stores expiring on different schedules would have
been a policy nobody decided on, one edit away.

`WorkspaceClearanceStore.mm` also carried its own complete set of schema
primitives (`ClearanceUUID`, `ClearanceDigest`, `ClearanceTimestamp`,
`ClearanceExactKeys`, …) — a third copy after `LocalWorkspaceAccess.mm` and the
core. The ones the ported rules used are gone; the rest still back the file's
storage paths and stay for now.

### Android reads its registry the way iOS does

Two things, and the second only became possible because of the first.

**One place says device ids are not durable.**
`DSHWorkspaceDescriptorMatchesAuthority` — the last rule left in
`LocalWorkspaceAccess.mm` — now asks `descriptor_matches_authority`. Only the
inode is compared, because iOS renumbers the data volume across reboots and a
persisted `st_dev` would fail a perfectly good root after a restart. What a
matching device id used to stand for, "this is inside our own container", is
carried by *how* the caller got the descriptor: it walked down from the app
container. That reasoning used to be written out twice, here and in the legacy
matcher. It is written once now.

**Android's registry uses the shared rules it was written before.**
`AndroidWorkspaceRegistry` was checking `schema_version`, `generation` and
`records` by hand and parsing with `JSONObject` directly. It now runs the byte
scanner before the parse and `registry_shape` after it, and asks
`registry_has_room` before creating — a bound it did not have at all.

**That change made ascending order a rule Android had to obey, and it did
not.** `create` appended; the registry it wrote would have failed to load on
the next launch. Caught while writing the change rather than by a test, but
`recordsAreStoredInAscendingWorkspaceIdOrder` now pins it. The order matters
for the reason given above: the registry's canonical JSON is what a journal's
`previous_registry_sha256` is taken over.

**`org.json` keeps the last of two duplicate keys, silently.**
`aRegistryWithADuplicateKeyIsRefusedBeforeItIsParsed` appends a second
`generation` to a real registry file and asserts two things: the scanner
refuses the bytes, *and* `JSONObject` happily parses them and reports a
generation nothing ever wrote. The second assertion is the one that says why
the scan has to happen before the parse rather than after.

The first version of that test put the duplicate first and expected it to win.
It lost — the original came later in the text. The fixture was wrong, not the
claim; it appends now.

### Whether stored bytes are JSON worth looking at

`workspace_json.rs` ports `DSHJSONHasBoundedExactStructure` and its scanner. It
runs before the parse, on raw bytes that may be corrupt or hand-edited: one
complete value, at most 64 levels and 100,000 nodes, no duplicate keys in any
object however spelled, no negative zero, nothing after it. It is the reason a
bad registry costs a refusal rather than an unbounded walk — and Android's
registry, which currently just calls `JSONObject(text)`, can now have the same
guard.

**The core already had two scanners of this shape, and this is a third.**
`strict_json` (tool arguments) and `session_schema::scanner` (the session
snapshot) look almost identical. They are not interchangeable:

| | top level | nodes | raw `0x7f` in a string |
| --- | --- | --- | --- |
| `strict_json` | object | 30,000 | refused |
| `session_schema::scanner` | object | 250,000 | refused |
| `workspace_json` | any value | 100,000 | **accepted** |

The third column is the one that matters. Reusing either of the others would
refuse a stored registry the current engine accepts. That file almost certainly
does not exist — Foundation escapes control characters when it writes, and
every string position refuses `0x7f` downstream anyway — but *almost certainly*
is not *verified*, and this is the acceptance rule for data already on people's
devices. A test asserts the difference rather than a comment claiming it.
Unifying the three is a decision to take knowingly, not one that arrives by
reuse.

This reducer takes the **raw bytes** rather than a JSON envelope, because the
question is about bytes that may not be JSON — there is nothing to put an
envelope around.

**One guard that is not load-bearing, said out loud.** The scanner's own
`< 0x20` check mirrors the ObjC line for line, but removing it leaves every
test green: serde refuses the same bytes when the token is decoded. The test
now says so and asserts the redundancy, rather than looking like proof it is
not.

### Sealing an authority, and the registry file itself

Two duplications closed.

**Sealing.** `workspace_fingerprint::seal` is the writing side of
`fingerprint_valid`: build the input, hash it, one step. The host used to do
that in three — `DSHAuthorityDigestWithoutFingerprint`, one of three
`*FingerprintInput` builders, `DSHWorkspaceRootFingerprintSHA256` — at each
creation site, which is the same rule written twice. All four helpers are gone
from `LocalWorkspaceAccess.mm`; `workspace_authority`'s own upgrade path uses
`seal` too, so an upgrade and a fresh write cannot seal differently.
`DSHWorkspaceRootFingerprintSHA256` stays in `DSHWorkspaceCanonical.mm`, where
`WorkspaceFingerprintParityTests` compares it against the core — that is the
evidence the two agree, and deleting it would delete the evidence.

**The registry file.** `registry_shape` now owns what `loadRegistry:` used to
check inline. Three invariants beyond "every record is a record":

- **Workspace ids are strictly ascending**, not merely unique. The registry's
  canonical JSON is what `previous_registry_sha256` is taken over, so the same
  records in a different order digest differently and every journal written
  against one would be unrecoverable against the other.
- **No two records share a folded directory name.** Two workspaces whose
  folders differ only by case or accent are one folder on this filesystem, and
  the second would silently write into the first.
- **The count is bounded** at 1024, which now has one copy rather than two.

The host folds each record's two names and hands them across in order; a short
list is refused rather than judged halfway.

**Asserting a constant proves nothing.** The first version of the capacity test
said `assert_eq!(MAX_RECORDS, 1024)` and nothing else, and deleting the bound
left it green. It now builds a registry of 1024 records and one of 1025.

`layout_manifest_shape` moved with it.

**What is deliberately *not* delegated:** the primitive predicates
(`DSHCanonicalUUID`, `DSHCanonicalTimestamp` and friends) still used at the
public API boundary, where they check a caller's arguments before anything is
read or written. They run dozens of times per launch and the composite rules
behind them all go through the core, so a duplicated primitive on an argument
path is a much smaller risk than a duplicated *stored shape* was. Said plainly
rather than quietly left.

### Which failure a caller is told about

`workspace_error.rs` ports `DSHWorkspacePublicCode` and
`DSHWorkspacePublicMessage`. This is contract, not a lookup table two
platforms may each keep a copy of: the public code is what the JS layer
branches on and what a person's retry depends on. `E_WORKSPACE_CONFLICT` says
"try again", `E_WORKSPACE_PERSISTENCE` says "this store cannot be read", and a
caller that cannot tell them apart cannot behave correctly.

The numbers 1..19 are on the wire, so the table is dense and unique and the
test says so. A number the engine does not define projects to nothing — no code
is invented for it, because a caller must not be able to branch on a failure
that does not exist.

The messages are the fixed English fallback the native layer attaches, not
localisation: the product's translated strings are chosen in the UI from the
code.

### What the host found when it re-read a legacy project

`legacy_evidence`, `capabilities_set` and `legacy_identity_matches_authority`
join the legacy rules already in `workspace_authority.rs`.

**Device ids are deliberately not compared.** iOS renumbers the data volume
across reboots, so a persisted `st_dev` is not evidence about a directory —
comparing it would fail a perfectly good legacy root after a restart. The three
inodes, all reached from this app's own container, carry the identity.

Evidence carries a capability **set**, where order does not matter; a stored
authority carries the ordered list. They are two rules, and
`evidence_capabilities_are_a_set_not_a_list` pins that one accepts what the
other refuses.

**An NSSet does not cross a JSON boundary.** The first delegation passed the
evidence dictionary straight into the envelope, `NSJSONSerialization` refused
to encode the `NSSet` under `capabilities`, the envelope never serialised, and
every legacy root became `E_WORKSPACE_UNAVAILABLE` — 192 failures. The host now
turns sets into arrays on the way out. Worth keeping: unlike the journal
identity relation, this path is *thoroughly* covered, and the suite said so
immediately.

### What an operation journal is, and how recovery reads it

`workspace_journal.rs` ports `validJournal:`, `validLegacyJournal:`,
`DSHCreateRequestSHA256`, `DSHBootstrapRequestSHA256`,
`DSHJournalIdentityPresent`, `DSHJournalIdentityMatchesState` and
`DSHOwnedAuthorityMatchesJournal`.

A journal is what makes a workspace operation recoverable: written before the
directory moves, updated as each phase lands, read on the next launch to decide
whether an interrupted operation should be finished or undone. Three rules
follow.

- **A journal binds itself to its own request.** `request_sha256` must be the
  digest of the request the journal claims to be carrying out, so a journal
  cannot be replayed as a different operation than the one that was asked for.
- **A phase says which digests exist yet.** `prepared` has neither an authority
  nor a record digest; any later phase has both. A journal claiming one at
  `prepared` describes a state that cannot have occurred.
- **Physical identity is recorded in fours.** Device, inode, uid and gid are
  present together or not at all. Three of four is not partial evidence — it is
  a journal no recovery engine can check against a directory.

Statting stays with the host, which passes the four numbers as the same
canonical decimal strings the journal holds. That comparison is exact rather
than a shortcut: a canonical unsigned string and the number it denotes are in
bijection, which is what makes insisting on the canonical spelling worth
anything.

**A coverage hole this cut found.** After delegating, making
`DSHJournalIdentityMatchesState` return `YES` unconditionally left all 68
`LocalWorkspaceAccessTests` green — the relation that decides whether a
journal's recorded directory is the one on disk was never exercised
negatively, on either side of the migration.
`testRecoveryRefusesAJournalWhoseIdentityIsNotTheDirectoryOnDisk` closes it:
it interrupts a create, edits the recorded inode, and asserts recovery refuses
with `E_WORKSPACE_CONFLICT` and leaves both the folder and the journal alone.
With that test present the same mutation fails.

One behaviour named rather than tightened: an identity-less authority and an
identity-less journal do "match", because `[NSNull isEqual:NSNull]` is `YES`
and the port reproduces it. It is unreachable — `owned_authority` requires
canonical unsigned strings before anything gets that far — and tightening it
would be a second reading of one rule on one platform.

### What a workspace operation receipt is

`workspace_receipt.rs` ports `validReceipt:`, `validLegacyReceipt:`,
`DSHPublicOperationReceipt`, the store checks in `loadReceipts:`, the capacity
check and the expiry test in `pruneReceipts:`.

A receipt is how a retried operation is recognised as the one that already
happened. Two things follow:

- **One operation id names one outcome.** A store holding the id twice cannot
  say which retry is the one that happened, so the store is refused whole
  rather than read past the duplicate.
- **`request_sha256` is an idempotency secret.** It binds the receipt to the
  request that produced it, so the public projection leaves it out — handing it
  over would let a caller claim recognition of an operation it never made. The
  projection enumerates its keys rather than copying them.

Two closed relations worth naming: only `delete_owned` can be `purge_pending`,
because only a delete leaves content behind to purge; and `bootstrap_legacy`
can only have committed, at revision 1, because bootstrapping is what *creates*
the binding — a bootstrap receipt at revision 2 would claim the binding existed
before it was made.

A1 receipts predate `request_sha256` and stay readable. They are not rewritten
in place: the record and the authority are what a retry is validated against,
so nothing is gained by inventing a digest for a request nobody kept. The two
shapes are each exact, so a new receipt cannot pass as an old one either.

The timestamp stays with the host — the calendar is Foundation's — and the host
passes the age it measured. A receipt whose timestamp will not parse counts as
expired: it can never be matched against a retry, so keeping it is pure cost.
The capacity moved too, so 2048 has one copy rather than two.

`testAReceiptStoreWithARepeatedOperationIdIsRefused` is new; the duplicate case
had no coverage. The public projection's withholding was already covered by two
existing query tests.

### Upgrading an authority written before fingerprints

The three `DSHMigrate*Authority` functions, `DSHValidLegacyPhysicalIdentity`
and the capability ordering now live in `workspace_authority.rs` beside the
validators they mirror. `DSHCapabilityOrder` is gone: the one order a stored
capability list may be spelled in has a single copy, in the core.

**Upgrading is sealing.** The same contents, with the fingerprint they imply.
Nothing is rewritten, so an upgrade can never turn an authority into a claim
over something its own bytes did not already say. An authority that already
carries a fingerprint is refused — the shape is exact — so a *broken* seal can
never be repaired into a working one.

Three asymmetries between migrating and validating, all the original's and all
left alone rather than tidied:

- The legacy migration requires the physical identity's metadata digest to be
  the authority's own `root_identity_sha256`. The validator never compares
  those two, so a stored legacy authority may carry different ones. Migration
  is the narrower gate on purpose: it is the step that decides what a root is
  worth *from evidence*, rather than reading back what someone already wrote.
- The legacy migration checks `created_at` and `last_opened_at` are canonical
  timestamps but not that they match the record's; the validator demands they
  match. So a drifted legacy authority upgrades into one that still fails to
  validate. The upgrade never invents agreement it did not find.
- The legacy fingerprint folds in **no** authority digest, which is why the
  caller can add the capability list after the seal and the seal still holds.
  That is load-bearing and also the honest limit of a legacy fingerprint: it
  covers the identity, not the whole object.

**The suite covered none of this before.** Nothing on iOS wrote a
pre-fingerprint authority, so the migration rules could have been anything.
`testAnAuthorityWrittenBeforeFingerprintsIsUpgradedInPlace` writes one and
checks it comes back sealed to exactly the fingerprint it had; it was verified
by making `DSHMigrateOwnedAuthority` return nil, which fails it.

`testAnIncompleteAuthorityIsNotUpgraded` was wrong on the first attempt: it
expected the listing to report that one workspace as unavailable. It does not —
it fails **closed** with `E_WORKSPACE_PERSISTENCE`. Storage that cannot be read
as itself is not one workspace in a bad state; it is storage that cannot be
trusted to describe any of them. Measured, then asserted.

### What a workspace's directory is called

`workspace_directory_name.rs` ports `DSHInternalComponent`,
`DSHTruncateDisplayNameForSuffix` and the naming half of
`allocateOwnedDirectoryNameForDisplayName:`.

**The loop stays with the host, the names do not.** Deciding whether a
candidate is taken needs folding, and folding is host-specific — Foundation
folds case and diacritics together under `en_US_POSIX`, a JVM host does
neither the same way. So the host walks ordinals and asks the core what each
ordinal is called. What each one *is* called is the rule.

**Truncation is a projection.** Foundation cuts on composed character
sequences. Cutting anywhere else writes a character nobody typed: a name of
fifteen 🇯🇵 flags is exactly 120 bytes, and making room for `" (1)"` on a byte
or scalar boundary would leave a lone regional indicator on the end. The host
supplies the clusters; the core decides where the cut falls, and a cluster goes
in whole or not at all.

`testOccupiedDisplayNameAtTheBoundIsTruncatedOnAClusterBoundary` pins that
against Foundation, and it was checked by making the host pass UTF-16 units
instead of clusters — it fails.

`NAME_MAX` is 255 on both Darwin and Linux, so that bound is in the core rather
than handed across.

### What a stored authority looks like

`workspace_authority.rs` is the fourth workspace rule, and the one that ties
the other three together. Four shapes — owned, bookmark, granted, legacy — each
restating its record's identity and each ending in the fingerprint from
`workspace_fingerprint`.

**The cross-check is the point.** An authority that is well formed but names a
different workspace, a different binding revision or (for a legacy root) a
different display name than the record it was loaded for is not that record's
authority. The owned shape goes further: its directory digest must be the
digest of the directory the *record* names, so an authority cannot claim a
folder the registry never bound. The granted shape carries the bookmark's
digest rather than the bookmark, and it must be the digest the bookmark
authority recorded — the two are halves of one grant.

**Base64 stays with the host.** The core has no base64, and decoding is
mechanical. The host decodes and passes the decoded length and SHA-256; the
rules — that the bytes fit the 256 KiB cap and that the claimed digest is the
digest of what decoded — travel. Bytes that did not decode are reported as
*absent*, never as zero bytes, so a broken string cannot read as an empty
bookmark.

Two Foundation notes:

- `isEqual:` compares two `NSNumber`s by value, so a binding revision written
  `3.0` still names binding 3. `same_value` reproduces that. The other
  `NSNumber` coincidence — `@YES` equalling `@1` — is deliberately *not*
  reproduced: nothing writes a boolean revision, and carrying that accident
  into the rule would widen it.
- Device and inode identifiers are canonical unsigned integer strings. They are
  tested against the rule directly rather than through a sealed authority: a
  non-canonical identifier also breaks the fingerprint input, so composing the
  two would not show which check did the work. **A test that two guards both
  reject something proves neither of them.**

The legacy shape's six device/inode fields are *positive*, not merely unsigned:
zero names nothing, and a legacy root reporting it is not verifiable.

### What a stored workspace record may do

`workspace_grants.rs` is the second workspace rule to move, and with
`root_projection::capabilities_for_grants` it completes the chain from a stored
record to what an agent may do with it: **locator kind → grants → Agent
capabilities**.

- a **documents-owned** root is produced and verified natively, so it grants
  read, write, git and project context;
- a **granted folder** grants read and write only. It has no native coordinated
  Git, project-context or Files producer, and the advertised contract stays
  honest until those consumers exist;
- a **legacy** root grants what the host could verify. Verification means
  re-reading the project metadata and comparing physical identity, which only
  the host can do, so the answer is handed across rather than guessed at —
  "could not verify" and "verified as nothing" both end in no grants, but they
  are not the same thing;
- nothing is granted unless the status is exactly `ok`.

Deriving the status stays with the host: it resolves a security-scoped
bookmark, starts a scope and stats a directory. What a status *means* travels.

`files_visible` is in the projection but is not a grant — it says the folder
shows up in Files, so it is true for a documents-owned root even when that root
is unavailable, and a capability list can never turn it on.

### The workspace root fingerprint

This is the first rule of the workspace subsystem to move, and it moves first
on purpose. The root fingerprint is what an Agent root projection carries and
what a lease proves, so **two implementations would mean an authority written
on one platform is invalid on the other**. Building Android's workspace
subsystem against a second Kotlin copy of this would have been the exact thing
the shared core exists to prevent — so the rule goes to the core before the
Android host code that will need it exists.

`workspace_fingerprint.rs` owns the three shapes and the digest:

- `rish_created` / `imported` → a directory this app owns: device, inode, and
  the digest of its name;
- `granted_folder` → a folder the person granted: volume and resource
  identifiers plus the security-scoped bookmark;
- `legacy_app_owned` → the pre-workspace layout: three separate device/inode
  pairs.

The first two fold in `authority_sha256`, the digest of the authority record
*without* its own fingerprint, so the fingerprint covers everything the record
says about itself and cannot be carried to a record that says something else.
That digest is a **plain** SHA-256 over canonical JSON, not domain-separated,
because that is what the stored records were written with.

Device and inode numbers travel as strings in their shortest decimal spelling:
they outrun a safe integer on some filesystems, and two spellings of one number
would be two roots.

**Verified by real parity, not by a replica agreeing with itself.** Both
implementations are still present, so `WorkspaceFingerprintParityTests` puts
the same inputs through `DSHWorkspaceRootFingerprintSHA256` and through the
core and asserts the digests are equal — for all three origins — and that both
refuse the same nine malformed inputs.

### Android serves its first agent operation

`AgentRuntime.prepare_agent_attempt` is no longer a rejection on Android. It
reads the committed session and writes the agent WAL through the shared core,
exactly as iOS does.

Every attempt there is **rootless**, because Android resolves no workspace
root, so the core commits it as `not_agent` / `E_AGENT_NO_ROOT`. That is a
definite answer — "this attempt gets no agent authority" — and it is a
different thing from `E_AGENT_NATIVE`, which says "there is no agent engine
here". The controller can treat an Android chat as an attempt without tools
rather than as a platform without an engine.

`implemented` stays `false`. The JS layer reads that constant as "the whole
agent surface is available", and one served operation is not that. The rest of
the surface still rejects.

### The cross-store seam, and what covers it

`prepare_agent_attempt` is the only operation that reads the committed session
and writes the agent WAL in one breath, and the two stores are not atomic with
each other: the session is SQLite, the WAL is a file. The window between "the
session says generation N" and "the WAL has committed an operation bound to N"
is the one place in the engine where a crash can leave them disagreeing, and
until now nothing exercised it on either platform.

`AndroidPreparedAttemptStore` plus `AndroidPreparedAttemptStoreTest` cover it —
with a scope that has to be stated, not assumed. Android can resolve no root,
so every attempt there is rootless, and the core commits a rootless attempt as
`not_agent` / `E_AGENT_NO_ROOT` with the operation in state `rejected`, no
authority and no transcript. **So this is the seam on the rejection path only.**
It covers the session read, the checkpoint relation, the durable WAL write,
replay of the same operation, and a fresh process finding the committed
operation rather than repeating it. It says nothing about successful authority
creation, which still needs the rooted iOS coverage.

Three things the session fixture had to get right, each of which cost a round
trip through the emulator before it was found by feeding the same bytes to the
core directly:

- **An attempt belongs to a turn.** `turns` is not decoration: the attempt's
  `turn_id` must name one, the turn must list the attempt, and the turn's
  `user_message_id` fixes exactly which messages the attempt may claim as
  visible.
- **A prepared attempt with no rounds carries no `visible_history_sha256`.**
  The digest only becomes meaningful once a round was sent; the schema refuses
  one without that provenance.
- **The committed session's bytes must be canonical.** The prepared-attempt
  store reads the *exact* bytes, so a fixture serialised in insertion order is
  refused — as the real controller's bytes never would be.

One branch is deliberately left uncovered and marked as such: the store refuses
a request naming a workspace with `E_AGENT_ROOT_STALE`, but that branch is
unreachable on Android today, because `session_matches` runs first and a stored
attempt can never carry a workspace here — `AndroidSessionStore` refuses to
persist a workspace-bound session at all. The request conflicts before the root
is ever consulted. The branch stays because it states the platform limit
honestly, but it is not covered and is not counted as covered.

### Where model output becomes executable

`DSHParseCompletionResponseSchema2` turned a provider's reply into the tool
calls the engine runs. That is the boundary where untrusted model output
becomes something executable — a call that gets through it is a call a person
will be asked to approve — so it is now `completion_response.rs`
(`rish_agent_completion_response_reduce`) and there is one copy of it.

Unlike the store reducers it answers with a `failure_code`, not a store error
code: a provider reply is not a store operation, and the controller uses these
to decide whether a retry could possibly help.

Two host facts stay behind, because the core cannot know them: whether a model
is in this build's catalogue, and a fresh identifier for the compatibility
path. Everything else is rule, including four worth naming:

- **A length-limited reply never yields an executable call.** A reply cut off
  mid-argument can still be syntactically valid JSON; running it would run a
  call the model never finished writing.
- **A tool call comes with the reasoning that produced it**, unless thinking
  was off — the one exception being the compatibility path, which never had a
  tool channel and so never had reasoning either.
- **The compatibility path is deliberately narrow.** A model that describes a
  call in prose is honoured only in two exact shapes, only when it sent no real
  calls at all. Anything looser and ordinary prose that happens to be JSON
  would become an executable call.
- **Only omission means create-only.** An explicit `expected_revision`,
  including a placeholder string, survives parsing so tool preparation can
  report it; coercing it to null would turn a malformed update into a create.

### Predicting the commit id

`AgentGitToolExecutor.mm` keeps libgit2 and hands the rest to `git_tool.rs`
(`rish_agent_git_tool_reduce`): which staged paths a commit may contain, the
exact bytes of the commit object, the id it will have, the timezone spelling,
and the failure a Git tool may report.

The id is the point. A `git_commit` precondition carries `expected_commit_oid` —
the id the commit *will* get — so a crash between libgit2 writing the object
and the ledger recording it is recoverable: the host looks for that exact id
afterwards. Two implementations of the payload encoding would predict two
different ids and the recovery would quietly find nothing. That is why the
payload digest and the id come back from one call: a caller that could take
them separately could mix two payloads.

**SHA-1 is written out in the core rather than pulled in as a dependency.** The
core had no SHA-1, and this is not a security primitive — Git's object format
specifies it and nothing here depends on it being hard to forge. It is pinned
against the standard vectors, and the commit case is pinned against
`git hash-object -t commit`, not against our own output. (The first draft of
that test asserted an id I had written by hand rather than measured; the
implementation was right and the literal was wrong.)

Two rules in the staged index worth keeping visible: only a plain or executable
blob may be committed — a symlink, a gitlink or a directory entry is refused —
and `.gitmodules` is refused by name, because a commit that introduces a
submodule introduces a second repository this engine never audited. A path that
escapes or names Git's own metadata is `E_AGENT_CONFLICT`, not
`E_AGENT_INVALID`: the call was well formed, the working tree is not in a state
this tool commits.

The `git_push` reason vocabulary is closed in the core, so no server text can
become a reason token in a transcript.

### The workspace executor decides nothing

`AgentWorkspaceToolExecutor.mm` had a small capability and a lot of rule around
it. The capability is a directory descriptor, bytes read and written, and
`fstatat`; everything else — which paths a tool may name, what a revision is,
what a listing looks like, what a person is shown before approving a write, and
what a failed tool reports — is now `workspace_tool.rs`
(`rish_agent_workspace_tool_reduce`).

The path rule was the third copy in the tree: `execution_ledger.rs` and
`tool_batch.rs` each had one, and this one added a per-component `NAME_MAX`
bound and the "." allowance a listing needs. They no longer have to agree by
inspection.

Two orderings are load-bearing and easy to lose:

- **The three ways a listing can refuse are reached in a fixed order.** In the
  original they were interleaved with the directory walk: a name that is not
  UTF-8 refuses straight away, but a full listing is at capacity *before* an
  entry that merely cannot be exposed — a symlink, a device, a hard-linked
  file — is judged. So the host now hands the core every entry `readdir`
  returned, in `readdir` order, reporting such an entry as `"invalid"` (or
  `"unnamed"`) rather than refusing it itself. That costs a few more `fstatat`
  calls than the old short-circuit and keeps the answer identical. A first
  version of this port refused in the host and got the capacity case wrong;
  the ordering only survives if the rule owns it.
- **A listing is ordered by name bytes**, not by locale, because the
  fingerprint the precondition is taken over has to be the same on every
  device that lists the same directory.

The byte caps (path, read, prior read, entry count) are rules too, so the host
asks the core for them once rather than keeping a second copy that could drift.
So is the protected cap on anything a workspace tool reports: 64 KiB, tighter
than the transcript bound the feedback contract itself applies, and applying to
every workspace tool rather than only the two that carry content.

### What a tool is allowed to report, once

`DSHAgentValidateNativeToolFeedbackString` was ~190 lines in `AgentNativeWAL.mm`
describing every tool's result payload. The same rule was already in the core
as `execution_ledger::feedback_string_valid`, which the ledger applies to every
stored row — and the Rust copy was ahead, because it had learned about the
runtime tools while the ObjC one was being kept in step by hand.

Two copies of the contract between "a tool ran" and "the engine believes
something" is one too many, so the ObjC function is now how a host reaches the
core's: `tool_feedback` on the WAL-state reducer. It answers through the error
code rather than a `valid` flag, because an oversized report is
`E_AGENT_CAPACITY` and a caller recovers from that differently than from a
malformed one.

Worth remembering when hunting for an existing rule before porting one: the
Rust name need not resemble the ObjC name. Grepping for
`DSHAgentValidateNativeToolFeedbackString` and for `tool_feedback` both missed
`feedback_string_valid`, and a first attempt at this cut wrote a second Rust
copy before the collision surfaced.

### Device-only storage metadata

The session store and the agent WAL require every pinned item to report
`NSFileProtectionCompleteUntilFirstUserAuthentication` and the expected
`NSURLIsExcludedFromBackupKey` value. That requirement is enforced on a
physical device only: `requiresSessionResourceMetadata` and
`requiresWALResourceMetadata` return `NO` on the simulator and on macOS,
because CoreSimulator does not report the protection class through
`NSFileManager`. The simulator suites cover the path through injected
file managers (`sessionFileManager`, `walFileManager`) and an overridden
requirement, so a change there must be exercised with those fakes; a green
simulator run is not evidence about a device.

An item created by an earlier build can carry a different protection class
or no backup exclusion. Both stores now re-apply the required metadata in
place once and read it back before refusing, the way `LocalWorkspaceAccess`
migrates a legacy `NSFileProtectionComplete` item. Without that repair an
upgraded container fails every WAL read with `E_AGENT_PERSISTENCE` and never
recovers, which the simulator can never show.

### Editing Objective-C by pattern

Two mistakes in this program came from replacing text between two markers found
by a plain search:

- the first occurrence of a selector is often its **declaration** in a class
  extension, not its implementation. Anchor the search after
  `@implementation <Class>`.
- the *end* marker must be searched for **after the start index**. Searching
  the whole file can return a declaration that sits earlier, which makes the
  end precede the start and silently duplicates everything between them. That
  produced "duplicate interface definition" errors a hundred lines away from
  the actual edit.

### Checking an Xcode build result

`grep "error:"` over `xcodebuild` output is not a build check. Objective-C
selector fragments such as `error:(NSError **)error` contain that substring, so
a build full of deprecation context matches it dozens of times, and a `head -N`
after the grep then hides the one line that mattered. A failing build read this
way looks clean, and the stale `.app` left behind fails to launch with
`Launchd job spawn failed` — which reads like a wedged simulator and is not.

Check the outcome, not the noise: `xcodebuild … | tail -3` and look for
`** TEST BUILD SUCCEEDED **`, or grep `"^\*\* "`.

## Quality gates

From the repository root:

```sh
node scripts/verify-source-checkout.mjs
cd apps/mobile
npm run typecheck
npm run lint
npm test -- --runInBand

cd android
./gradlew assembleDebug

cd ../../..
ruby scripts/verify-no-bundled-secret.rb
ruby scripts/verify-no-bundled-secret.rb \
  apps/mobile/ios/build/local-proof-arm64/Build/Products/Release-iphonesimulator/Rish.app
```

The Jest suite covers typed state/persistence, theme and locale resolution,
chat isolation/history, request cancellation/retry, reasoning, structured tool
display, the Markdown subset, credential recovery, workspace create/edit with
revision protection, and portable-tool receipts. The native Release build and
the proof verifier remain separate required gates.

The TestFlight Release gate also runs the real first-send storage graph:
workspace creation, session CAS checkpoints, prepared Agent authority, native
WAL, round journal, a scripted HTTP response and exact replay without another
request. Agent WAL protection uses `NSFileManager` for both writing and fresh
readback, with strict device checks for protection and backup exclusion. Tests
inject device metadata failures while keeping real file descriptors, inode
checks and atomic writes, and require the previous committed bytes to survive.
Simulator and macOS results do not establish the state of an existing device's
storage; physical-device reports still need confirmation.

Run this graph with the production `RISH_GUEST_CGI_ENABLED=1` define. The CGI
tool description previously exceeded the 1,024-character transport limit,
rejecting every Agent request that advertised it before HTTP dispatch. Keep
descriptions within that bound and test the actual capability-filtered tool
set. Round-create and dispatch failures are also injected into the real WAL:
an uncommitted in-memory row must never be returned as a successful write or
permit a provider request.

The real CGI HTTP client uses one 60-second host-time deadline across connect,
send and receive. A POST stages its body, executes the backend and removes the
temporary file through multiple software-guest exchanges; the backend's
five-second guest-shell timeout is not an end-to-end host-time bound. The test
requires complete responses and the exact counter sequence without retries,
and records timings without cookies or request contents.

For a native `complete_agent_round_v2` persistence rejection, error details
include a fixed diagnostic marker distinguishing storage failure, unavailable
dependencies and an exception. This marker is transient display information;
it never changes persisted failure codes or recovery authority and contains no
raw native error message, exception reason, path or credential.

## What is still missing

- The complete `local_harness` qualification and full upstream Harness
  coverage. The implemented bounded API-driven Agent loop, registered tools,
  approvals, journal, and recovery paths do not establish general Harness or
  official CLI compatibility. A general provider/plugin host and structured
  question flow remain outside the verified scope.
- Token/reasoning/event streaming; the current native request returns one
  completed response.
- DSH plans, goals, jobs, subagents, workflow runs, queues, steering, skills,
  plugins, agent presets, usage/stats, and produced-file event integration.
- Share-extension input, OCR for scanned PDFs, full DSH Markdown parity beyond
  the supported mobile subset, and message edit/regenerate/export/feedback
  actions.
- Git pull/fetch UI, merge/rebase, SSH profile picker/restart UI, encrypted SSH
  private-key formats, LFS, submodules, signed commits, and SSH push. The
  current Git slice intentionally supports a smaller auditable HTTPS workflow
  plus native SSH clone/fetch.
- Android native local runtime/workspace adapters and device proof.

Detailed DSH parity, mobile UI, and runtime proof records are maintained
separately from this source repository. This README keeps the implementation
boundary and known limitations self-contained for a source checkout.
