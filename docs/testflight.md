# iOS TestFlight builds

The `iOS TestFlight` GitHub Actions workflow builds the React Native app and
its pinned Rust/libgit2/libssh2/OpenSSL dependencies on `macos-26`, using Xcode
26.6 (17F113) and the iOS 26.5 SDK required by `prepare-rish-ios.sh`.
It signs both the app and Live Activity extension, exports an App Store IPA,
saves the IPA and dSYMs for 14 days, and optionally uploads to App Store Connect.

## Apple setup (one time)

In the Apple Developer account, register explicit identifiers:

- Main app: `tech.zseven.rish`
- Live Activity extension: `tech.zseven.rish.taskactivity`

Create the Rish app record in App Store Connect with the main identifier.
Create an Apple Distribution certificate and export it **with its private key**
as a password-protected `.p12`. Create one App Store Connect distribution
provisioning profile for each identifier using that certificate. Both profiles
must belong to the same team and support the target's entitlements.

Create a team App Store Connect API key with permission to upload builds
(Developer is sufficient for this upload-only workflow). Download its `.p8` once and keep it securely.
The app's `Info.plist` declares `ITSAppUsesNonExemptEncryption` as Boolean
`false`, as confirmed by the app owner. Future uploads carry this declaration
automatically. Revisit it if the app's encryption or exemption status changes.

## GitHub setup

Create the `testflight` Environment in this repository. Restrict its deployment
branches to reviewed release branches (initially `main`). Add these secrets:

| Secret | Value |
| --- | --- |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 of the distribution `.p12` |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64 of the main app's App Store profile |
| `IOS_EXTENSION_PROVISIONING_PROFILE_BASE64` | Base64 of the extension's App Store profile |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64 of the API key `.p8` |
| `APP_STORE_CONNECT_API_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |

For file secrets, this pattern reads the file directly into GitHub without
printing its contents (replace the secret name and local file path):

```sh
base64 < /path/to/distribution.p12 | gh secret set IOS_DISTRIBUTION_CERTIFICATE_BASE64 \
  --repo ZSeven-W/rish-app --env testflight
```

Use GitHub's secret form or `gh secret set`'s hidden interactive prompt for
passwords. Do not commit certificates, profiles, or keys. The team ID is derived
from and cross-checked between the profiles; no additional team secret is needed.

## Run

Commit and push the workflow to `main` before its first dispatch. In Actions,
select **iOS TestFlight → Run workflow**, choose `main`, and enter the marketing
version (default `1.0.0`). Keep **Upload** enabled to send the build to Apple;
disable it to only produce a signed IPA. Signing secrets are required in both
modes; API secrets are required only for upload.

The build number is `<GitHub run number>.<run attempt>`, shared by the app and
extension. Rerunning a job produces a new build number. Avoid uploading higher
manual build numbers for the same marketing version; if one already exists,
start a new marketing version or adjust the numbering before dispatch.

A successful upload means Apple accepted the upload request. Wait for Apple
processing, then enable the build for an
internal testing group. External testing may require Beta App Review.
The workflow does not submit an App Store release or enable external testers.

The base build uses the repository's default native runtime configuration.

## Local preview service

TestFlight builds enable `RISH_IOS_GUEST_CGI_ENABLED=1` when installing Pods.
The Release simulator gate verifies the native service tool is registered,
boots the real bundled Linux guest, fetches its HTML page, calls a stateful
JSON API, and stops the service. A skipped live test does not satisfy the gate.
The pinned rish source includes the agent-ready handshake fix; native cache
keys include the preparation script so a source pin change rebuilds the library.

The available service is a temporary local HTTP preview: self-contained HTML
at `/` plus a BusyBox `/bin/sh` handler for `POST /api`. The handler receives
the request-body file as `$1` and a mutable JSON state file as `$2`; stdout is
returned as JSON. It is not a general Node.js/npm server or a persistent iOS
background service. Existing tool approval and workspace capability checks
still apply. After updating the app, send a new request to start the preview;
an already denied attempt from an older build remains denied in its history.

The bundled guest agent must use the same ready-marker protocol as the host.
Its build source and hashes are recorded in `GuestAssets/guest-agent-build.json`.
After building the musl guest agent from the pinned rish source, use
`python3 scripts/refresh-guest-agent.py /path/to/rish` to replace the guest-agent and init-script
archive entries and refresh the integrity pins. The other rootfs files and
offline APK packages are preserved. Both CI lanes check the image hashes
and the presence of the expected agent-ready marker.

## Session startup and recovery

The Release simulator gate also exercises fresh session creation, cross-launch
loading, exact-byte legacy migration, and file/directory protection metadata.
Protection uses fresh `NSFileManager` attributes; the exact protection class is
still enforced on physical devices. Simulator results do not establish device
lock/unlock enforcement.

The model catalog loads before stored conversations are validated. Load
validation caches are scoped to that catalog, so a retry after catalog recovery
revalidates the original bytes. A failed load retains a stable error code and
keeps session writes, reconciliation, and attachment pruning gated until a
successful read. **Retry loading chats** reads the existing store again; it is
not a reset and does not replace rejected data with an empty session. Error
notices do not include native filesystem paths or stored conversation content.
