#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Product acceptance test for the LOCAL Apple app against production (main).
# The iOS simulator drives instant-account creation, logout, secret-key login,
# password login, and Connect UI reachability.  The signed macOS destination
# drives the same lifecycle and additionally connects the real Network
# Extension, verifies a changed public egress IP, and disconnects.
#
# Usage:
#   ./test-main.sh                 build and test iOS + macOS
#   ./test-main.sh --repeat=5      run each complete platform flow five times
#   ./test-main.sh --ios-only      simulator only
#   ./test-main.sh --macos-only    signed macOS app only
#   ./test-main.sh --skip-build    reuse cached DerivedData/build IDs
#   ./test-main.sh --keep-fixture  retain the private instant-account fixture
#   ./test-main.sh --headless      do not open the Simulator application
#
# Environment:
#   UR_ACCEPT_VAULT=<path>         alternate main acceptance credentials
#   UR_ACCEPT_FIXTURE=<path>       persistent private instant-account fixture
#   UR_ACCEPT_REPEAT=<n>           repetition count
#   UR_ACCEPT_APPLE_SIMULATOR=<n>  simulator name (urnetwork-acceptance)
#   UR_ACCEPT_APPLE_TOOLS=<path>   setup-managed Go mobile tools/cache
#   UR_ACCEPT_KEEP_FIXTURE=1       retain the private instant-account fixture
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
root="${URNETWORK_ROOT:-$(dirname "$here")}"
vault="${UR_ACCEPT_VAULT:-$root/vault/main/test-acceptance.yml}"
fixture="${UR_ACCEPT_FIXTURE:-$here/tests/__acceptance__/fixtures/apple-main.secret}"
repeat_count="${UR_ACCEPT_REPEAT:-1}"
skip_build="${SKIP_BUILD:-0}"
headless="${HEADLESS:-0}"
keep_fixture="${UR_ACCEPT_KEEP_FIXTURE:-0}"
platforms="ios macos"

for arg in "$@"; do
  case "$arg" in
    --repeat=*) repeat_count="${arg#*=}" ;;
    --ios-only) platforms="ios" ;;
    --macos-only) platforms="macos" ;;
    --skip-build) skip_build=1 ;;
    --keep-fixture) keep_fixture=1 ;;
    --headless) headless=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
case "$repeat_count" in
  ''|*[!0-9]*) echo "--repeat must be a positive integer" >&2; exit 2 ;;
  0) echo "--repeat must be at least 1" >&2; exit 2 ;;
esac

die() { echo "[apple acceptance] ERROR: $*" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || die "GNU timeout is required (brew install coreutils)"
node "$root/build/all/acceptance/preflight-main.mjs" || exit 1
[ -f "$vault" ] || die "no acceptance vault at $vault"
acc_user="$(awk -F': *' '$1=="user"{print $2; exit}' "$vault")"
acc_pass="$(awk -F': *' '$1=="pass"{print $2; exit}' "$vault")"
[ -n "$acc_user" ] && [ -n "$acc_pass" ] || die "$vault must contain user: and pass:"

simulator_name="${UR_ACCEPT_APPLE_SIMULATOR:-urnetwork-acceptance}"
simulator_udid="$(xcrun simctl list devices available | sed -n "s/^[[:space:]]*${simulator_name} (\([^)]*\)).*/\1/p" | sed -n '1p')"
case " $platforms " in
  *" ios "*) [ -n "$simulator_udid" ] || die "simulator $simulator_name is missing; run $root/build/all/apple/setup.sh" ;;
esac

timestamp="$(date +%Y%m%d-%H%M%S)"
artifacts="$here/tests/__acceptance__/$timestamp"
cache="$here/tests/__acceptance__/build"
mkdir -p "$artifacts" "$cache" "$(dirname "$fixture")"
clipboard_dir="$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-clipboard.XXXXXX")"
chmod 700 "$clipboard_dir"
host_clipboard_saved=0
simulator_clipboard_saved=0
active_platform=""
simulator_was_booted=0
if [ -n "$simulator_udid" ] && xcrun simctl list devices | grep -F "$simulator_udid" | grep -q Booted; then
  simulator_was_booted=1
fi

release_platform_clients() {
  local out="$1" log="$1/test.log" marker="$1/.clients-cleaned" client_ids client_id active index=0 result=0
  [ -f "$marker" ] && return 0
  [ -f "$log" ] || return 0
  client_ids="$(grep -oE 'UR_ACCEPTANCE_CLIENT id=[A-Za-z0-9._-]+' "$log" | sed 's/.*id=//' | sort -u || true)"
  while read -r client_id; do
    [ -n "$client_id" ] || continue
    index=$((index + 1))
    active="$out/active-client-id-$index"
    printf '%s\n' "$client_id" >"$active"
    chmod 600 "$active"
    if ! UR_ACCEPT_USER="$acc_user" UR_ACCEPT_PASS="$acc_pass" \
      timeout 90 node "$root/build/all/acceptance/client-cleanup.mjs" "$active"; then
      result=1
    fi
  done <<<"$client_ids"
  if [ "$result" -eq 0 ]; then
    touch "$marker"
  fi
  return "$result"
}

cleanup() {
  exit_status=$?
  local simulator_state=""
  rm -f "$cache/ios/Build/Products/.acceptance.xctestrun" "$cache/macos/Build/Products/.acceptance.xctestrun"
  if [ -n "$simulator_udid" ]; then
    timeout 15 xcrun simctl terminate "$simulator_udid" network.ur >/dev/null 2>&1 || true
  fi
  timeout 15 osascript -e 'tell application id "network.ur" to quit' >/dev/null 2>&1 || true
  for platform_out in "$artifacts/ios" "$artifacts/macos"; do
    if ! release_platform_clients "$platform_out"; then
      echo "[apple acceptance] could not release every retained network client in $platform_out" >&2
      exit_status=1
    fi
  done
  if [ ! -f "$fixture" ]; then
    case "$active_platform" in
      ios) pull_fixture ios || true ;;
      macos) pull_fixture macos || true ;;
    esac
    if [ -n "$active_platform" ] && [ ! -f "$fixture" ]; then
      echo "[apple acceptance] no recoverable secret was available during interrupted $active_platform cleanup" >&2
    fi
  fi
  if [ "$simulator_clipboard_saved" -eq 1 ] && [ -n "$simulator_udid" ]; then
    if ! timeout 5 xcrun simctl pbcopy "$simulator_udid" <"$clipboard_dir/simulator.txt" >/dev/null 2>&1; then
      echo "[apple acceptance] could not restore the simulator text clipboard" >&2
      exit_status=1
    fi
  fi
  if [ "$host_clipboard_saved" -eq 1 ]; then
    if ! timeout 5 pbcopy <"$clipboard_dir/host.txt" >/dev/null 2>&1; then
      echo "[apple acceptance] could not restore the host text clipboard" >&2
      exit_status=1
    fi
  fi
  if [ -n "$simulator_udid" ] && [ "$simulator_was_booted" -eq 0 ]; then
    timeout 30 xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    if ! simulator_state="$(timeout 15 xcrun simctl list devices)"; then
      echo "[apple acceptance] could not verify the acceptance simulator state" >&2
      exit_status=1
    elif printf '%s\n' "$simulator_state" | grep -F "$simulator_udid" | grep -q Booted; then
      echo "[apple acceptance] could not stop the acceptance simulator" >&2
      exit_status=1
    fi
  fi
  if ! rm -rf "$clipboard_dir"; then
    echo "[apple acceptance] could not remove $clipboard_dir" >&2
    exit_status=1
  fi
  echo
  if [ "$exit_status" -eq 0 ]; then
    echo "[apple acceptance] ✓ ACCEPTANCE PASSED (artifacts: $artifacts)"
  else
    echo "[apple acceptance] ✗ ACCEPTANCE FAILED (artifacts: $artifacts)"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$skip_build" -ne 1 ]; then
  tools_dir="${UR_ACCEPT_APPLE_TOOLS:-$root/build/all/apple/.acceptance-tools}"
  case "$tools_dir" in
    /*) ;;
    *) tools_dir="$root/$tools_dir" ;;
  esac
  for tool in gomobile gobind checksec; do
    [ -x "$tools_dir/go-bin/$tool" ] || \
      die "$tool is missing; run $root/build/all/apple/setup.sh"
  done
  case "$(uname -m)" in arm64|aarch64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; *) die "unsupported Apple build architecture" ;; esac
  warpctl="$root/warp/warpctl/build/darwin/$host_arch/warpctl"
  [ -x "$warpctl" ] || die "local warpctl is missing; run $root/build/all/apple/setup.sh"
  if [ -n "${WARP_VERSION:-}" ]; then
    sdk_version="$WARP_VERSION"
  else
    sdk_version="$("$warpctl" ls version)+$("$warpctl" ls version-code)"
  fi
  case "$sdk_version" in
    ''|*[!A-Za-z0-9.+-]*) die "local SDK version contains unsupported characters" ;;
  esac
  echo "[apple acceptance] building the local Apple SDK"
  mkdir -p "$clipboard_dir/go-cache" "$clipboard_dir/go-mod-cache"
  (
    cd "$root/sdk/build"
    WARP_VERSION="$sdk_version" \
      GOCACHE="$clipboard_dir/go-cache" \
      GOMODCACHE="$clipboard_dir/go-mod-cache" \
      GOPATH="$tools_dir/go-path" \
      GOBIN="$tools_dir/go-bin" \
      PATH="$tools_dir/go-bin:$PATH" \
      timeout 3600 make build_apple
  ) 2>&1 | tee "$artifacts/sdk-build.log"
else
  [ -d "$root/sdk/build/apple/URnetworkSdk.xcframework" ] || \
    die "Apple SDK is missing; run without --skip-build"
fi

pull_fixture() {
  local source="$1" temporary="$artifacts/.guest-secret-key"
  if [ "$source" = ios ]; then
    if ! timeout 5 xcrun simctl pbpaste "$simulator_udid" >"$temporary" 2>/dev/null; then
      rm -f "$temporary"
      return 1
    fi
  else
    if ! timeout 5 pbpaste >"$temporary" 2>/dev/null; then
      rm -f "$temporary"
      return 1
    fi
  fi
  if [ "$(wc -w <"$temporary" | tr -d ' ')" = 24 ]; then
    chmod 600 "$temporary"
    mv "$temporary" "$fixture"
    chmod 600 "$fixture"
  else
    rm -f "$temporary"
    return 1
  fi
}

verify_app_marker() {
  local app_path="$1" expected="$2" plist actual
  if [ -f "$app_path/Contents/Info.plist" ]; then plist="$app_path/Contents/Info.plist"; else plist="$app_path/Info.plist"; fi
  actual="$(/usr/libexec/PlistBuddy -c 'Print :URAcceptanceBuildID' "$plist" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || die "built app marker mismatch: expected $expected, got ${actual:-missing}"
}

prepare_xctestrun() {
  local derived="$1" output="$2" build_id="$3" platform="$4" source secret=""
  source="$(find "$derived/Build/Products" -maxdepth 1 -name '*.xctestrun' ! -name '.acceptance.xctestrun' -print | sort | sed -n '1p')"
  [ -f "$source" ] || die "xctestrun file is missing from $derived"
  cp "$source" "$output"
  chmod 600 "$output"
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_USER -string "$acc_user" "$output"
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_PASS -string "$acc_pass" "$output"
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_BUILD_ID -string "$build_id" "$output"
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_PLATFORM -string "$platform" "$output"
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_REPEAT -string "$repeat_count" "$output"
  if [ -f "$fixture" ]; then
    secret="$(tr '\r\n\t' '   ' <"$fixture" | tr -s ' ')"
    [ "$(printf '%s\n' "$secret" | awk '{print NF}')" -eq 24 ] || die "fixture must contain a 24-word secret key"
  fi
  /usr/bin/plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_SECRET -string "$secret" "$output"
}

verify_test_log() {
  local log="$1" platform="$2" pass_count
  if grep -q 'Test skipped' "$log"; then
    echo "[apple acceptance] $platform UI test was skipped" >&2
    return 1
  fi
  pass_count="$(grep -c "UR_ACCEPTANCE_PASS repetition=.* platform=$platform" "$log" || true)"
  if [ "$pass_count" -ne "$repeat_count" ]; then
    echo "[apple acceptance] expected $repeat_count completed $platform repetitions, found $pass_count" >&2
    return 1
  fi
}

run_ios() {
  local out="$artifacts/ios" derived="$cache/ios" sidecar="$cache/ios.build-id" build_id app_path test_status xctestrun
  mkdir -p "$out"
  xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
  timeout 180 xcrun simctl bootstatus "$simulator_udid" -b
  [ "$headless" -eq 1 ] || open -a Simulator >/dev/null 2>&1 || true

  if [ "$skip_build" -ne 1 ]; then
    build_id="${timestamp}-ios"
    rm -rf "$derived"
    timeout 3600 xcodebuild build-for-testing \
      -project "$here/app/app.xcodeproj" \
      -scheme URnetworkUITests \
      -destination "platform=iOS Simulator,id=$simulator_udid" \
      -derivedDataPath "$derived" \
      -configuration Debug \
      CODE_SIGNING_ALLOWED=NO \
      URNETWORK_ACCEPTANCE_BUILD_ID="$build_id" \
      2>&1 | tee "$out/build.log"
    printf '%s\n' "$build_id" >"$sidecar"
  else
    [ -f "$sidecar" ] || die "missing iOS build-id sidecar; run without --skip-build"
    build_id="$(tr -d '\r\n' <"$sidecar")"
  fi

  app_path="$(find "$derived/Build/Products" -type d -name URnetwork.app -not -path '*/PlugIns/*' -print | sort | sed -n '1p')"
  [ -d "$app_path" ] || die "iOS acceptance app is missing from $derived"
  verify_app_marker "$app_path" "$build_id"

  xctestrun="$derived/Build/Products/.acceptance.xctestrun"
  prepare_xctestrun "$derived" "$xctestrun" "$build_id" ios

  if [ "$simulator_clipboard_saved" -eq 0 ]; then
    if ! timeout 5 xcrun simctl pbpaste "$simulator_udid" >"$clipboard_dir/simulator.txt" 2>/dev/null; then
      die "could not save the simulator text clipboard"
    fi
    simulator_clipboard_saved=1
  fi
  printf '' | timeout 5 xcrun simctl pbcopy "$simulator_udid"
  active_platform=ios
  set +e
  timeout "$((600 + repeat_count * 600))" xcodebuild test-without-building \
    -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived" \
    -only-testing:networkUITests/networkUITests/testMainAcceptance \
    -resultBundlePath "$out/result.xcresult" \
    2>&1 | tee "$out/test.log"
  test_status=${PIPESTATUS[0]}
  set -e
  rm -f "$xctestrun"
  if [ "$test_status" -eq 0 ] && ! verify_test_log "$out/test.log" ios; then test_status=1; fi
  pull_fixture ios || true
  if [ ! -f "$fixture" ]; then
    echo "[apple acceptance] iOS retained no recoverable instant-account fixture" >&2
    test_status=1
  fi
  if ! release_platform_clients "$out"; then
    echo "[apple acceptance] iOS network-client cleanup failed" >&2
    test_status=1
    platform_cleanup_failed=1
  fi
  timeout 30 xcrun simctl spawn "$simulator_udid" log show --style compact --last 30m \
    --predicate 'process == "URnetwork"' >"$out/system.log" 2>&1 || true
  timeout 30 xcrun simctl uninstall "$simulator_udid" network.ur >/dev/null 2>&1 || true
  active_platform=""
  platform_status="$test_status"
  return 0
}

run_macos() {
  local out="$artifacts/macos" derived="$cache/macos" sidecar="$cache/macos.build-id" build_id app_path test_status xctestrun
  mkdir -p "$out"
  if [ "$skip_build" -ne 1 ]; then
    build_id="${timestamp}-macos"
    rm -rf "$derived"
    timeout 3600 xcodebuild build-for-testing \
      -project "$here/app/app.xcodeproj" \
      -scheme URnetworkUITests \
      -destination 'platform=macOS' \
      -derivedDataPath "$derived" \
      -configuration Debug \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM=6BGU69Q742 \
      URNETWORK_ACCEPTANCE_BUILD_ID="$build_id" \
      2>&1 | tee "$out/build.log"
    printf '%s\n' "$build_id" >"$sidecar"
  else
    [ -f "$sidecar" ] || die "missing macOS build-id sidecar; run without --skip-build"
    build_id="$(tr -d '\r\n' <"$sidecar")"
  fi

  app_path="$(find "$derived/Build/Products" -type d -name URnetwork.app -not -path '*/PlugIns/*' -print | sort | sed -n '1p')"
  [ -d "$app_path" ] || die "macOS acceptance app is missing from $derived"
  verify_app_marker "$app_path" "$build_id"

  xctestrun="$derived/Build/Products/.acceptance.xctestrun"
  prepare_xctestrun "$derived" "$xctestrun" "$build_id" macos

  if [ "$host_clipboard_saved" -eq 0 ]; then
    if ! timeout 5 pbpaste >"$clipboard_dir/host.txt" 2>/dev/null; then
      die "could not save the host text clipboard"
    fi
    host_clipboard_saved=1
  fi
  printf '' | timeout 5 pbcopy
  active_platform=macos
  set +e
  timeout "$((600 + repeat_count * 600))" xcodebuild test-without-building \
    -xctestrun "$xctestrun" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    -only-testing:networkUITests/networkUITests/testMainAcceptance \
    -resultBundlePath "$out/result.xcresult" \
    2>&1 | tee "$out/test.log"
  test_status=${PIPESTATUS[0]}
  set -e
  rm -f "$xctestrun"
  if [ "$test_status" -eq 0 ] && ! verify_test_log "$out/test.log" macos; then test_status=1; fi
  pull_fixture macos || true
  if [ ! -f "$fixture" ]; then
    echo "[apple acceptance] macOS retained no recoverable instant-account fixture" >&2
    test_status=1
  fi
  if ! release_platform_clients "$out"; then
    echo "[apple acceptance] macOS network-client cleanup failed" >&2
    test_status=1
    platform_cleanup_failed=1
  fi
  timeout 30 log show --style compact --last 30m --predicate 'process == "URnetwork"' >"$out/system.log" 2>&1 || true
  active_platform=""
  platform_status="$test_status"
  return 0
}

overall=0
for platform in $platforms; do
  echo
  echo "[apple acceptance] ════════ $platform ════════"
  platform_status=0
  platform_cleanup_failed=0
  "run_$platform"
  if [ "$platform_status" -eq 0 ]; then
    echo "[apple acceptance] $platform accepted"
  else
    echo "[apple acceptance] $platform rejected" >&2
    overall=1
  fi

  if [ "$platform_cleanup_failed" -eq 1 ]; then
    echo "[apple acceptance] stopping after network-client cleanup failed" >&2
    break
  fi

  # Do not let a later destination create another production guest after an
  # earlier destination reached account creation but failed to return a
  # recoverable credential to the host.
  if [ ! -f "$fixture" ]; then
    echo "[apple acceptance] stopping before another platform can create an unrecoverable account" >&2
    overall=1
    break
  fi
done

if [ "$overall" -eq 0 ] && [ "$keep_fixture" -ne 1 ] && [ -f "$fixture" ]; then
  if timeout 90 node "$root/build/all/acceptance/fixture.mjs" delete "$fixture"; then
    rm -f "$fixture"
  else
    echo "could not delete instant-account fixture; retained at $fixture" >&2
    overall=1
  fi
fi

exit "$overall"
