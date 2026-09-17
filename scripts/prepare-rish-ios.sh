#!/bin/zsh
set -euo pipefail

# This is deliberately pinned. Updating rish for the app is a reviewed source
# upgrade, not an accidental consequence of whatever happens to be checked out
# next door when the mobile dependencies are prepared.
readonly EXPECTED_RISH_COMMIT="9020e9648115bd9ae8eb5215dd3e7ac76620da3f"
readonly EXPECTED_RISH_REMOTE="git@github.com:ZSeven-W/rish.git"
readonly EXPECTED_RISH_PUBLIC_REMOTE="https://github.com/ZSeven-W/rish.git"
readonly EXPECTED_HEADER_SHA256="ba15e5084739538acc5edc7c5bb12638272c5594a548c77ba23d5e22d94e422f"
readonly EXPECTED_CARGO_LOCK_SHA256="88571f30fd4496f9efbe5834dc91c087fc35836140f906fc91712092bfed537e"
readonly EXPECTED_CRATE_VERSION="0.1.0"
readonly RUST_TOOLCHAIN="1.94"
readonly EXPECTED_RUSTC_RELEASE="1.94.1"
readonly EXPECTED_RUSTC_COMMIT="e408947bfd200af42db322daf0fadfe7e26d3bd1"
readonly IOS_DEPLOYMENT_TARGET="15.1"
readonly EXPECTED_XCODE_VERSION="Xcode 26.6"
readonly EXPECTED_XCODE_BUILD="Build version 17F113"
readonly EXPECTED_IPHONEOS_SDK="26.5"
readonly EXPECTED_IPHONESIMULATOR_SDK="26.5"

readonly SCRIPT_DIR=${0:A:h}
readonly APP_ROOT=${SCRIPT_DIR:h}
# Accept an explicitly selected sibling checkout so a fresh clone does not
# depend on the maintainer's local workspace layout. The checkout remains
# pinned and dirty-tree checked below.
# A caller may provide a reviewed checkout through either name. With neither
# set, the script creates a temporary detached clone from the public HTTPS
# repository and removes it on exit; it never mutates a user's sibling tree.
readonly RISH_SOURCE_ARG=${RISH_SOURCE_DIR:-${RISH_IOS_RISH_ROOT:-${1:-}}}
readonly OFFLINE=${RISH_IOS_OFFLINE:-0}
RISH_ROOT=""
rish_source_tmp=""
readonly MODULE_ROOT=${APP_ROOT}/modules/rish/ios
readonly VENDOR_ROOT=${MODULE_ROOT}/Vendor
readonly INCLUDE_ROOT=${MODULE_ROOT}/include
readonly XCFRAMEWORK_OUTPUT=${VENDOR_ROOT}/rish_ffi.xcframework
readonly VERSION_OUTPUT=${VENDOR_ROOT}/rish_ffi.version
readonly HEADER_OUTPUT=${INCLUDE_ROOT}/rish.h

readonly DEVICE_TARGET="aarch64-apple-ios"
readonly SIMULATOR_TARGET="aarch64-apple-ios-sim"

fail() {
  print -u2 -- "prepare-rish-ios: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_archive() {
  local library=$1
  local expected_platform=$2
  local label=$3
  local architectures

  [[ -f "${library}" ]] || fail "${label} archive was not produced: ${library}"

  architectures=$(xcrun lipo -archs "${library}")
  [[ "${architectures}" == "arm64" ]] || \
    fail "${label} archive has architecture '${architectures}', expected arm64"

  # Xcode's numeric LC_BUILD_VERSION platform values are 2 for iOS device and
  # 7 for iOS Simulator. Rust's prebuilt iOS device stdlib still contains
  # LC_VERSION_MIN_IPHONEOS members, so validate every archive member and
  # accept that legacy command only for the device slice. This prevents an
  # arm64 macOS object from hiding in an otherwise valid iOS archive.
  /usr/bin/otool -l "${library}" |
    /usr/bin/awk \
      -v expected="${expected_platform}" \
      -v label="${label}" \
      -v deployment="${IOS_DEPLOYMENT_TARGET}" '
      function version_leq(actual, maximum, actual_parts, maximum_parts, position) {
        split(actual, actual_parts, ".")
        split(maximum, maximum_parts, ".")
        for (position = 1; position <= 3; position++) {
          if ((actual_parts[position] + 0) < (maximum_parts[position] + 0)) return 1
          if ((actual_parts[position] + 0) > (maximum_parts[position] + 0)) return 0
        }
        return 1
      }
      function finish_member() {
        if (member == "") return
        if (markers != 1 || valid != 1 || minimum == "" || !version_leq(minimum, deployment)) {
          print label ": invalid platform load command in " member \
            " (markers=" markers ", valid=" valid ", minimum=" minimum ")" > "/dev/stderr"
          bad++
        }
      }
      index($0, ".a(") > 0 && substr($0, length($0), 1) == ":" {
        finish_member()
        member = $0
        markers = 0
        valid = 0
        minimum = ""
        mode = ""
        members++
        next
      }
      $1 == "cmd" && $2 == "LC_BUILD_VERSION" {
        mode = "build"
        next
      }
      mode == "build" && $1 == "platform" {
        markers++
        if ($2 == expected) valid++
        mode = ""
        next
      }
      $1 == "minos" {
        minimum = $2
        next
      }
      $1 == "cmd" && $2 ~ /^LC_VERSION_MIN_/ {
        markers++
        if (expected == 2 && $2 == "LC_VERSION_MIN_IPHONEOS") valid++
        mode = "legacy"
        next
      }
      mode == "legacy" && $1 == "version" {
        minimum = $2
        mode = ""
        next
      }
      END {
        finish_member()
        if (members == 0) {
          print label ": no Mach-O members found" > "/dev/stderr"
          bad++
        }
        if (bad) exit 1
      }
    ' || fail "${label} archive contains a wrong or unclassified Mach-O member"

  for symbol in \
    _rish_plan_json \
    _rish_protocol_version \
    _rish_execute_applet_json \
    _rish_pull_image_json \
    _rish_vm_run_docker_json \
    _rish_vm_boot_session \
    _rish_vm_boot_session_cancellable \
    _rish_vm_cancel_new \
    _rish_vm_cancel_request \
    _rish_vm_cancel_free \
    _rish_vm_session_exec_json \
    _rish_vm_session_exec_stream_json \
    _rish_vm_session_free \
    _rish_string_free; do
    xcrun nm -gU "${library}" 2>/dev/null | \
      /usr/bin/grep "[[:space:]]${symbol}$" >/dev/null || \
      fail "${label} archive is missing exported symbol ${symbol}"
  done
}

verify_xcframework() {
  local xcframework_root=$1
  local expected_header=$2
  local info=${xcframework_root}/Info.plist
  [[ -f "${info}" ]] || fail "XCFramework Info.plist is missing"

  local identifiers
  identifiers=$(
    /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "${info}" |
      /usr/bin/awk '/LibraryIdentifier = / { print $3 }' |
      /usr/bin/sort |
      /usr/bin/tr '\n' ' ' |
      /usr/bin/sed 's/[[:space:]]*$//'
  )
  [[ "${identifiers}" == "ios-arm64 ios-arm64-simulator" ]] || \
    fail "XCFramework slices are '${identifiers}', expected ios-arm64 and ios-arm64-simulator"

  verify_archive \
    "${xcframework_root}/ios-arm64/librish_ffi.a" \
    "2" \
    "packaged iOS device"
  verify_archive \
    "${xcframework_root}/ios-arm64-simulator/librish_ffi.a" \
    "7" \
    "packaged iOS Simulator"

  /usr/bin/cmp -s "${expected_header}" "${xcframework_root}/ios-arm64/Headers/rish.h" || \
    fail "device slice header differs from the pinned rish.h"
  /usr/bin/cmp -s "${expected_header}" "${xcframework_root}/ios-arm64-simulator/Headers/rish.h" || \
    fail "simulator slice header differs from the pinned rish.h"
}

build_root=""
lock_dir=""
lock_acquired=false
publish_in_progress=false
publish_complete=false
next_xcframework=""
next_header=""
next_version=""
previous_xcframework=""
previous_header=""
previous_version=""
original_xcframework=false
original_header=false
original_version=false

rollback_outputs() {
  if [[ -n "${previous_xcframework}" && -e "${previous_xcframework}" ]]; then
    /bin/rm -rf -- "${XCFRAMEWORK_OUTPUT}" || true
    /bin/mv "${previous_xcframework}" "${XCFRAMEWORK_OUTPUT}" || true
  elif [[ "${original_xcframework}" == false ]]; then
    /bin/rm -rf -- "${XCFRAMEWORK_OUTPUT}" || true
  fi

  if [[ -n "${previous_header}" && -e "${previous_header}" ]]; then
    /bin/rm -f -- "${HEADER_OUTPUT}" || true
    /bin/mv "${previous_header}" "${HEADER_OUTPUT}" || true
  elif [[ "${original_header}" == false ]]; then
    /bin/rm -f -- "${HEADER_OUTPUT}" || true
  fi

  if [[ -n "${previous_version}" && -e "${previous_version}" ]]; then
    /bin/rm -f -- "${VERSION_OUTPUT}" || true
    /bin/mv "${previous_version}" "${VERSION_OUTPUT}" || true
  elif [[ "${original_version}" == false ]]; then
    /bin/rm -f -- "${VERSION_OUTPUT}" || true
  fi
}

cleanup() {
  if [[ "${publish_in_progress}" == true && "${publish_complete}" == false ]]; then
    rollback_outputs
  fi
  [[ -n "${next_xcframework}" ]] && /bin/rm -rf -- "${next_xcframework}" || true
  [[ -n "${next_header}" ]] && /bin/rm -f -- "${next_header}" || true
  [[ -n "${next_version}" ]] && /bin/rm -f -- "${next_version}" || true
  [[ -n "${build_root}" && -d "${build_root}" ]] && /bin/rm -rf -- "${build_root}" || true
  [[ -n "${rish_source_tmp}" && -d "${rish_source_tmp}" ]] && /bin/rm -rf -- "${rish_source_tmp}" || true
  if [[ "${lock_acquired}" == true && -n "${lock_dir}" ]]; then
    /bin/rmdir "${lock_dir}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

require_command cargo
require_command git
require_command jq
require_command rustc
require_command rustup
require_command tar
require_command xcodebuild
require_command xcrun

[[ "${OFFLINE}" == 0 || "${OFFLINE}" == 1 ]] || \
  fail "RISH_IOS_OFFLINE must be 0 or 1"
build_rust_toolchain=${RUST_TOOLCHAIN}
if [[ "${OFFLINE}" == 1 ]]; then
  # A +version proxy may auto-install a missing Rust toolchain. Resolve only
  # from the installed inventory, then keep that full name for every command.
  installed_toolchains=$(rustup toolchain list --quiet) || \
    fail "could not inspect installed Rust toolchains"
  build_rust_toolchain=$(
    print -r -- "${installed_toolchains}" |
      /usr/bin/awk -v requested="${RUST_TOOLCHAIN}" \
        '$1 == requested || index($1, requested "-") == 1 { print $1; exit }'
  )
  [[ -n "${build_rust_toolchain}" ]] || \
    fail "offline preparation requires preinstalled Rust ${RUST_TOOLCHAIN}; install the pinned toolchain before retrying"
fi
if [[ -n "${RISH_SOURCE_ARG}" ]]; then
  RISH_ROOT=${RISH_SOURCE_ARG:A}
  [[ -d "${RISH_ROOT}" ]] || fail "rish source checkout does not exist: ${RISH_ROOT}"
else
  [[ "${OFFLINE}" == 0 ]] || \
    fail "offline preparation requires RISH_SOURCE_DIR or an explicit reviewed checkout path"
  rish_source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/rish-ios-source.XXXXXX")
  RISH_ROOT=${rish_source_tmp}/rish
  git init --quiet "${RISH_ROOT}"
  git -C "${RISH_ROOT}" remote add origin "${EXPECTED_RISH_PUBLIC_REMOTE}"
  git -C "${RISH_ROOT}" fetch --quiet --depth=1 origin "${EXPECTED_RISH_COMMIT}" ||
    fail "could not fetch pinned rish commit from ${EXPECTED_RISH_PUBLIC_REMOTE}"
  git -C "${RISH_ROOT}" checkout --quiet --detach "${EXPECTED_RISH_COMMIT}" ||
    fail "could not check out pinned rish commit ${EXPECTED_RISH_COMMIT}"
fi

rustc_release=$(rustc +"${build_rust_toolchain}" -vV | /usr/bin/awk '/^release:/ { print $2 }')
rustc_commit=$(rustc +"${build_rust_toolchain}" -vV | /usr/bin/awk '/^commit-hash:/ { print $2 }')
[[ "${rustc_release}" == "${EXPECTED_RUSTC_RELEASE}" && \
  "${rustc_commit}" == "${EXPECTED_RUSTC_COMMIT}" ]] || \
  fail "Rust ${RUST_TOOLCHAIN} resolved to ${rustc_release}/${rustc_commit}; expected ${EXPECTED_RUSTC_RELEASE}/${EXPECTED_RUSTC_COMMIT}"

xcode_version_line=$(xcodebuild -version | /usr/bin/sed -n '1p')
xcode_build_line=$(xcodebuild -version | /usr/bin/sed -n '2p')
device_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
[[ "${xcode_version_line}" == "${EXPECTED_XCODE_VERSION}" && \
  "${xcode_build_line}" == "${EXPECTED_XCODE_BUILD}" ]] || \
  fail "Xcode is ${xcode_version_line}/${xcode_build_line}; expected ${EXPECTED_XCODE_VERSION}/${EXPECTED_XCODE_BUILD}"
[[ "${device_sdk}" == "${EXPECTED_IPHONEOS_SDK}" && \
  "${simulator_sdk}" == "${EXPECTED_IPHONESIMULATOR_SDK}" ]] || \
  fail "iOS SDKs are ${device_sdk}/${simulator_sdk}; expected ${EXPECTED_IPHONEOS_SDK}/${EXPECTED_IPHONESIMULATOR_SDK}"

git -C "${RISH_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "expected a Git source checkout at ${RISH_ROOT}"
actual_commit=$(git -C "${RISH_ROOT}" rev-parse HEAD)
actual_remote=$(git -C "${RISH_ROOT}" remote get-url origin)
[[ "${actual_commit}" == "${EXPECTED_RISH_COMMIT}" ]] || \
  fail "rish HEAD is ${actual_commit}; expected pinned commit ${EXPECTED_RISH_COMMIT}"
case "${actual_remote}" in
  "${EXPECTED_RISH_REMOTE}"|"${EXPECTED_RISH_PUBLIC_REMOTE}"|ssh://git@github.com/ZSeven-W/rish.git)
    ;;
  *)
    fail "rish origin is ${actual_remote}; expected the canonical ZSeven-W/rish repository"
    ;;
esac
[[ -z "$(git -C "${RISH_ROOT}" status --porcelain=v1 --untracked-files=all)" ]] || \
  fail "rish checkout is dirty; refusing to package beside unreviewed source"

for target in "${DEVICE_TARGET}" "${SIMULATOR_TARGET}"; do
  rustup target list --installed --toolchain "${build_rust_toolchain}" |
    /usr/bin/grep -x "${target}" >/dev/null || \
    fail "Rust target ${target} is not installed; run: rustup target add --toolchain ${RUST_TOOLCHAIN} ${target}"
done

/bin/mkdir -p "${VENDOR_ROOT}" "${INCLUDE_ROOT}"
lock_dir=${VENDOR_ROOT}/.prepare-rish-ios.lock
/bin/mkdir "${lock_dir}" 2>/dev/null || \
  fail "another packaging run holds ${lock_dir}; remove it only if no build is running"
lock_acquired=true

build_root=$(mktemp -d "${TMPDIR:-/tmp}/rish-ios-xcframework.XXXXXX")
[[ -n "${build_root}" && -d "${build_root}" ]] || fail "could not create build directory"
source_root=${build_root}/rish-source
/bin/mkdir -p "${source_root}"

# Build an immutable snapshot instead of the mutable adjacent checkout. The
# explicit revision also feeds rish's build identity when .git is absent.
git -C "${RISH_ROOT}" archive --format=tar "${EXPECTED_RISH_COMMIT}" |
  /usr/bin/tar -x -C "${source_root}"
source_header=${source_root}/platform/rish.h
actual_header_sha=$(sha256_file "${source_header}")
actual_lock_sha=$(sha256_file "${source_root}/Cargo.lock")
[[ "${actual_header_sha}" == "${EXPECTED_HEADER_SHA256}" ]] || \
  fail "archived rish.h SHA-256 is ${actual_header_sha}; expected ${EXPECTED_HEADER_SHA256}"
[[ "${actual_lock_sha}" == "${EXPECTED_CARGO_LOCK_SHA256}" ]] || \
  fail "archived Cargo.lock SHA-256 is ${actual_lock_sha}; expected ${EXPECTED_CARGO_LOCK_SHA256}"

# Remove ambient code-generation inputs. Populate Cargo's content-addressed
# cache from the pinned lockfile on a fresh machine, after rejecting user-level
# Cargo config. RISH_IOS_OFFLINE=1 requires an already populated cache; both
# release builds always stay offline/frozen against the verified lockfile.
dependency_cache_root=${CARGO_HOME:-${HOME}/.cargo}
for cargo_config in "${dependency_cache_root}/config" "${dependency_cache_root}/config.toml"; do
  [[ ! -e "${cargo_config}" ]] || \
    fail "ambient Cargo config is not allowed during release packaging: ${cargo_config}"
done
unset AR CC CFLAGS CPPFLAGS CXX CXXFLAGS LD LDFLAGS RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_TARGET SDKROOT || true
unset CARGO_REGISTRIES_CRATES_IO_INDEX CARGO_REGISTRIES_CRATES_IO_PROTOCOL CARGO_NET_GIT_FETCH_WITH_CLI || true
export LC_ALL=C
export TZ=UTC
export ZERO_AR_DATE=1
export CARGO_HOME=${dependency_cache_root}
export CARGO_TARGET_DIR=${build_root}/cargo-target
export IPHONEOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}
export RISH_SOURCE_REVISION=${EXPECTED_RISH_COMMIT}
export SOURCE_DATE_EPOCH=$(git -C "${RISH_ROOT}" show -s --format=%ct "${EXPECTED_RISH_COMMIT}")
fetch_options=(--locked)
[[ "${OFFLINE}" == 1 ]] && fetch_options+=(--offline)
(
  cd "${source_root}"
  cargo +"${build_rust_toolchain}" fetch \
    "${fetch_options[@]}" \
    --target "${DEVICE_TARGET}" \
    --target "${SIMULATOR_TARGET}"
)
crate_version=$(
  cd "${source_root}"
  cargo +"${build_rust_toolchain}" metadata --frozen --no-deps --format-version 1 |
    /usr/bin/jq -r '.packages[] | select(.name == "rish-ffi") | .version'
)
[[ "${crate_version}" == "${EXPECTED_CRATE_VERSION}" ]] || \
  fail "rish-ffi version is ${crate_version}; expected ${EXPECTED_CRATE_VERSION}"

for target in "${DEVICE_TARGET}" "${SIMULATOR_TARGET}"; do
  print -- "building immutable rish-ffi ${EXPECTED_RISH_COMMIT} for ${target}"
  (
    cd "${source_root}"
    cargo +"${build_rust_toolchain}" build \
      --frozen \
      --release \
      --target "${target}" \
      -p rish-ffi
  )
done

device_library=${CARGO_TARGET_DIR}/${DEVICE_TARGET}/release/librish_ffi.a
simulator_library=${CARGO_TARGET_DIR}/${SIMULATOR_TARGET}/release/librish_ffi.a
verify_archive "${device_library}" "2" "iOS device"
verify_archive "${simulator_library}" "7" "iOS Simulator"

stage_root=${build_root}/stage
stage_headers=${stage_root}/Headers
stage_xcframework=${stage_root}/rish_ffi.xcframework
/bin/mkdir -p "${stage_headers}"
/bin/cp "${source_header}" "${stage_headers}/rish.h"
xcodebuild -create-xcframework \
  -library "${device_library}" \
  -headers "${stage_headers}" \
  -library "${simulator_library}" \
  -headers "${stage_headers}" \
  -output "${stage_xcframework}"
verify_xcframework "${stage_xcframework}" "${source_header}"

rustc_version=$(rustc +"${build_rust_toolchain}" --version)
cargo_version=$(cargo +"${build_rust_toolchain}" --version)
xcode_version="${xcode_version_line};${xcode_build_line}"
device_sha=$(sha256_file "${stage_xcframework}/ios-arm64/librish_ffi.a")
simulator_sha=$(sha256_file "${stage_xcframework}/ios-arm64-simulator/librish_ffi.a")
header_sha=$(sha256_file "${source_header}")
info_sha=$(sha256_file "${stage_xcframework}/Info.plist")
version_stage=${stage_root}/rish_ffi.version
{
  print -- "format=1"
  print -- "source=https://github.com/ZSeven-W/rish"
  print -- "source_remote=${EXPECTED_RISH_PUBLIC_REMOTE}"
  print -- "source_snapshot=git-archive"
  print -- "commit=${EXPECTED_RISH_COMMIT}"
  print -- "crate=rish-ffi"
  print -- "crate_version=${crate_version}"
  print -- "rust_toolchain=${RUST_TOOLCHAIN}"
  print -- "rustc=${rustc_version}"
  print -- "cargo=${cargo_version}"
  print -- "cargo_dependency_mode=verified-cache-offline-frozen"
  print -- "cargo_home_config=none"
  print -- "ambient_codegen_flags=cleared"
  print -- "xcode=${xcode_version}"
  print -- "ios_deployment_target=${IOS_DEPLOYMENT_TARGET}"
  print -- "iphoneos_sdk=${device_sdk}"
  print -- "iphonesimulator_sdk=${simulator_sdk}"
  print -- "architectures=ios-arm64,ios-simulator-arm64"
  print -- "device_platform=LC_BUILD_VERSION:2-or-LC_VERSION_MIN_IPHONEOS"
  print -- "simulator_platform=LC_BUILD_VERSION:7"
  print -- "header_sha256=${header_sha}"
  print -- "cargo_lock_sha256=${actual_lock_sha}"
  print -- "xcframework_info_sha256=${info_sha}"
  print -- "device_library_sha256=${device_sha}"
  print -- "simulator_library_sha256=${simulator_sha}"
  print -- "source_date_epoch=${SOURCE_DATE_EPOCH}"
} > "${version_stage}"

# Copy the fully verified set to hidden paths on the destination filesystem,
# then swap it in with rollback. The version manifest moves last and acts as
# the commit marker for consumers that verify artifact hashes.
suffix=${$}
next_xcframework=${VENDOR_ROOT}/.rish_ffi.xcframework.next.${suffix}
next_header=${INCLUDE_ROOT}/.rish.h.next.${suffix}
next_version=${VENDOR_ROOT}/.rish_ffi.version.next.${suffix}
previous_xcframework=${VENDOR_ROOT}/.rish_ffi.xcframework.previous.${suffix}
previous_header=${INCLUDE_ROOT}/.rish.h.previous.${suffix}
previous_version=${VENDOR_ROOT}/.rish_ffi.version.previous.${suffix}
/usr/bin/ditto "${stage_xcframework}" "${next_xcframework}"
/bin/cp "${source_header}" "${next_header}"
/bin/cp "${version_stage}" "${next_version}"
verify_xcframework "${next_xcframework}" "${next_header}"

[[ -e "${XCFRAMEWORK_OUTPUT}" ]] && original_xcframework=true
[[ -e "${HEADER_OUTPUT}" ]] && original_header=true
[[ -e "${VERSION_OUTPUT}" ]] && original_version=true
publish_in_progress=true
if [[ "${original_xcframework}" == true ]]; then
  /bin/mv "${XCFRAMEWORK_OUTPUT}" "${previous_xcframework}" || fail "could not back up existing XCFramework"
fi
if [[ "${original_header}" == true ]]; then
  /bin/mv "${HEADER_OUTPUT}" "${previous_header}" || fail "could not back up existing rish.h"
fi
if [[ "${original_version}" == true ]]; then
  /bin/mv "${VERSION_OUTPUT}" "${previous_version}" || fail "could not back up existing provenance"
fi
/bin/mv "${next_xcframework}" "${XCFRAMEWORK_OUTPUT}" || fail "could not publish XCFramework"
/bin/mv "${next_header}" "${HEADER_OUTPUT}" || fail "could not publish rish.h"
/bin/mv "${next_version}" "${VERSION_OUTPUT}" || fail "could not publish provenance"
verify_xcframework "${XCFRAMEWORK_OUTPUT}" "${HEADER_OUTPUT}"
[[ "$(sha256_file "${XCFRAMEWORK_OUTPUT}/ios-arm64/librish_ffi.a")" == "${device_sha}" ]] || \
  fail "published device library hash changed"
[[ "$(sha256_file "${XCFRAMEWORK_OUTPUT}/ios-arm64-simulator/librish_ffi.a")" == "${simulator_sha}" ]] || \
  fail "published simulator library hash changed"
[[ "$(sha256_file "${VERSION_OUTPUT}")" == "$(sha256_file "${version_stage}")" ]] || \
  fail "published provenance hash changed"
publish_complete=true
publish_in_progress=false
/bin/rm -rf -- "${previous_xcframework}"
/bin/rm -f -- "${previous_header}" "${previous_version}"

print -- "prepared pinned rish iOS XCFramework at ${XCFRAMEWORK_OUTPUT}"
print -- "  iOS device: arm64, platform 2/legacy iPhoneOS, deployment <= ${IOS_DEPLOYMENT_TARGET}"
print -- "  iOS Simulator: arm64, platform 7, deployment <= ${IOS_DEPLOYMENT_TARGET}"
print -- "  provenance: ${VERSION_OUTPUT}"
