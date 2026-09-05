#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Deterministic, no-VPN startup regression on every attached eligible physical
# iOS device and disposable simulators for iOS 16, 17, 18, and 2026 (iOS 26).
# This lane never runs account, tunnel, VPN, peer, or data-plane cases.
#
# Usage:
#   ./test-hardware-startup.sh
#
# Environment:
#   UR_ACCEPT_REPEAT=N  Run both deterministic corpora N times per device.
#
# Physical and simulator inventories are captured into immutable plans. There
# are deliberately no device or test selectors: a caller cannot silently omit
# a required iOS release or attached eligible device, or substitute a tunnel
# test into this lane. Missing simulator runtimes are installed automatically.
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
root="${URNETWORK_ROOT:-$(dirname "$here")}"
source "$here/test-hardware-startup-lib.sh"
result_matrix="${UR_ACCEPT_RESULT_FILE:-}"
repeat_count="${UR_ACCEPT_REPEAT:-1}"

if [ "$#" -ne 0 ]; then
  case "${1:-}" in
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
  echo "[apple hardware startup] unknown arguments; this lane has no selectors" >&2
  exit 2
fi
case "$repeat_count" in
  ''|*[!0-9]*|0)
    echo "[apple hardware startup] UR_ACCEPT_REPEAT must be a positive integer" >&2
    exit 2
    ;;
esac

die() {
  echo "[apple hardware startup] ERROR: $*" >&2
  exit 1
}

for command_name in go ioreg jq make openssl shasum timeout xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "required command is missing: $command_name"
done
[ "$(uname -s)" = Darwin ] || die "iOS device startup tests require macOS"
network_test_gate="$root/tests/network-intensive-suite-lock.sh"
[ -x "$network_test_gate" ] || {
  echo "[apple hardware startup] network-intensive suite gate is missing: $network_test_gate" >&2
  exit 127
}
if [ "${URNETWORK_NETWORK_TEST_LOCK_HELD:-}" != 1 ]; then
  exec "$network_test_gate" apple-ios-device-startup -- "$here/test-hardware-startup.sh" "$@"
fi
if ! "$network_test_gate" --verify-held; then
  echo "[apple hardware startup] inherited suite-gate ownership is invalid" >&2
  exit 70
fi

acceptance_root="$here/tests/__hardware_startup__"
mkdir -p "$acceptance_root"

timestamp="$(date -u +%Y%m%d-%H%M%SZ)"
artifacts="$acceptance_root/$timestamp"
mkdir "$artifacts" || die "artifact directory already exists: $artifacts"
inventory="$artifacts/xcdevice-inventory.json"
inventory_log="$artifacts/xcdevice-inventory.log"
usb_ioreg_inventory="$artifacts/usb-ioreg-inventory.txt"
usb_identifiers="$artifacts/usb-ios-identifiers.txt"
plan="$artifacts/device-plan.json"
device_skips="$artifacts/device-skips.tsv"
results_root="$artifacts/devices"
runtime_inventory_before="$artifacts/simulator-runtimes-before.json"
runtime_inventory="$artifacts/simulator-runtimes.json"
runtime_download_logs="$artifacts/simulator-runtime-downloads"
simulator_plan="$artifacts/simulator-plan.json"
simulator_results_root="$artifacts/simulators"
owned_simulators="$artifacts/owned-simulators.tsv"
physical_derived="$artifacts/DerivedData-physical"
simulator_derived="$artifacts/DerivedData-simulator"
mkdir "$results_root" "$runtime_download_logs" "$simulator_results_root"

device_count=0
simulator_count=0
active_simulator_lane=""
active_simulator_udid=""
active_simulator_name=""

run_bounded() {
  timeout --foreground "$@"
}

devicectl_json() {
  local output="$1" log="$2"
  shift 2
  [ ! -e "$output" ] || return 2
  run_bounded 45 xcrun devicectl "$@" \
    --quiet --timeout 30 --json-output "$output" --log-output "$log"
  [ -s "$output" ]
}

query_installed_app() {
  local device_id="$1" bundle_id="$2" output="$3" log="$4"
  devicectl_json "$output" "$log" device info apps \
    --device "$device_id" --bundle-id "$bundle_id"
}

cleanup_sequence=0
cleanup_device() {
  local device_id="$1" device_out
  local bundle_id safe_bundle query log uninstall_json uninstall_log result=0
  device_out="$results_root/$device_id"

  for bundle_id in network.ur network.ur.networkUITests.xctrunner; do
    safe_bundle="${bundle_id//./-}"
    cleanup_sequence=$((cleanup_sequence + 1))
    query="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-query.json"
    log="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-query.log"
    if ! query_installed_app "$device_id" "$bundle_id" "$query" "$log"; then
      result=1
      continue
    fi
    if apple_hardware_app_query_has_bundle "$query" "$bundle_id"; then
      cleanup_sequence=$((cleanup_sequence + 1))
      uninstall_json="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-uninstall.json"
      uninstall_log="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-uninstall.log"
      if ! devicectl_json "$uninstall_json" "$uninstall_log" \
        device uninstall app --device "$device_id" "$bundle_id"; then
        result=1
        continue
      fi
      cleanup_sequence=$((cleanup_sequence + 1))
      query="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-verify.json"
      log="$device_out/cleanup-${cleanup_sequence}-${safe_bundle}-verify.log"
      if ! query_installed_app "$device_id" "$bundle_id" "$query" "$log" || \
         ! apple_hardware_app_query_is_clean "$query" "$bundle_id"; then
        result=1
      fi
    elif ! apple_hardware_app_query_is_clean "$query" "$bundle_id"; then
      result=1
    fi
  done
  return "$result"
}

# Invoked indirectly by the EXIT/INT/TERM traps installed below.
# shellcheck disable=SC2329
cleanup() {
  local exit_status=$? device_id marker trap_cleanup_log
  trap - EXIT INT TERM
  set +e

  if [ -f "$plan" ]; then
    while IFS= read -r device_id; do
      marker="$results_root/$device_id/.cleanup-required"
      [ -f "$marker" ] || continue
      if cleanup_device "$device_id"; then
        rm -f "$marker"
      else
        echo "[apple hardware startup] cleanup failed for $device_id" >&2
        exit_status=1
      fi
    done < <(apple_hardware_plan_ids "$plan" 2>/dev/null)
  fi

  # A signal can arrive after simctl returns a new UDID but before the normal
  # ownership journal write. Recover that exact identity into the journal
  # before attempting any destructive cleanup.
  if [ -n "$active_simulator_udid" ]; then
    mkdir -p "$simulator_results_root/$active_simulator_lane"
    if { [ -f "$owned_simulators" ] && \
         apple_ios_owned_simulator_journal_has_identity \
           "$owned_simulators" "$active_simulator_lane" \
           "$active_simulator_udid" "$active_simulator_name"; } || \
       apple_ios_append_owned_simulator \
         "$owned_simulators" "$active_simulator_lane" \
         "$active_simulator_udid" "$active_simulator_name"; then
      touch "$simulator_results_root/$active_simulator_lane/.cleanup-required"
    else
      echo "[apple iOS devices] could not journal active simulator $active_simulator_udid; leaving it in place" >&2
      exit_status=1
    fi
  fi
  if [ -f "$owned_simulators" ] && \
     [ -n "$(find "$simulator_results_root" -name .cleanup-required -type f -print -quit)" ]; then
    trap_cleanup_log="$artifacts/simulator-trap-cleanup.tsv"
    if ! apple_ios_cleanup_owned_simulators \
      "$owned_simulators" "$simulator_results_root" "$trap_cleanup_log"; then
      echo "[apple iOS devices] one or more disposable simulators could not be removed" >&2
      exit_status=1
    fi
  fi

  if [ -n "$result_matrix" ]; then
    mkdir -p "$(dirname "$result_matrix")"
    if [ "$exit_status" -eq 0 ]; then
      printf 'apple\thardware-startup-no-vpn\tPASS\t%s physical device(s) and %s required simulator lane(s) passed\n' \
        "$device_count" "$simulator_count" >>"$result_matrix"
    else
      printf 'apple\thardware-startup-no-vpn\tFAIL\tiOS device no-VPN startup failed; see Apple device artifacts\n' \
        >>"$result_matrix"
    fi
    chmod 600 "$result_matrix"
  fi

  if [ "$exit_status" -eq 0 ]; then
    echo "[apple iOS devices] ✓ PASSED (artifacts: $artifacts)"
  else
    echo "[apple iOS devices] ✗ FAILED (artifacts: $artifacts)" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "[apple hardware startup] capturing the physical iOS inventory once"
inventory_temporary="$artifacts/.xcdevice-inventory.json.tmp"
if ! run_bounded 45 xcrun xcdevice list --timeout=30 \
  >"$inventory_temporary" 2>"$inventory_log"; then
  die "xcdevice inventory failed"
fi
mv "$inventory_temporary" "$inventory"
chmod 400 "$inventory"

if ! minimum_ios_version="$({
    run_bounded 120 xcodebuild \
      -project "$here/app/app.xcodeproj" \
      -target networkUITests \
      -configuration Debug \
      -sdk iphoneos \
      -showBuildSettings
  } 2>"$artifacts/deployment-target.log" | awk -F ' = ' \
    '$1 ~ /^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET$/ { print $2 }' | \
    LC_ALL=C sort -u)"; then
  die "could not resolve the iOS UI-test deployment target"
fi
[ "$(printf '%s\n' "$minimum_ios_version" | wc -l | tr -d ' ')" -eq 1 ] || \
  die "could not resolve one iOS UI-test deployment target"
case "$minimum_ios_version" in
  [0-9]*.[0-9]*) ;;
  *) die "iOS UI-test deployment target is malformed" ;;
esac
minimum_ios_major="${minimum_ios_version%%.*}"
minimum_ios_remainder="${minimum_ios_version#*.}"
minimum_ios_minor="${minimum_ios_remainder%%.*}"
case "$minimum_ios_major:$minimum_ios_minor" in
  *[!0-9:]*|:*|*:) die "iOS UI-test deployment target is malformed" ;;
esac

case "$(uname -m)" in
  arm64|aarch64)
    host_arch=arm64
    # Older catalog entries reject a forced architecture even when Xcode then
    # resolves the unqualified request to a Universal image. Let Apple's
    # catalog choose the only offered variant.
    runtime_architecture=default
    ;;
  x86_64|amd64)
    host_arch=amd64
    runtime_architecture=default
    ;;
  *) die "unsupported Apple SDK build architecture" ;;
esac

capture_runtime_inventory() {
  local output="$1" temporary="${1}.tmp"
  [ ! -e "$output" ] && [ ! -e "$temporary" ] || return 2
  if ! run_bounded 60 xcrun simctl list runtimes --json >"$temporary" || \
     ! jq -e '(.runtimes | type) == "array"' "$temporary" >/dev/null; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 400 "$temporary"
  mv "$temporary" "$output"
}

echo "[apple iOS devices] ensuring simulator runtimes for iOS 16, 17, 18, and 2026 (iOS 26)"
capture_runtime_inventory "$runtime_inventory_before" || \
  die "could not inventory installed iOS simulator runtimes"
apple_ios_download_missing_simulator_runtimes \
  "$runtime_inventory_before" "$runtime_download_logs" \
  "$runtime_architecture" || \
  die "could not install every required iOS simulator runtime"
capture_runtime_inventory "$runtime_inventory" || \
  die "could not inventory iOS simulator runtimes after provisioning"
apple_ios_write_simulator_runtime_plan \
  "$runtime_inventory" "$simulator_plan" || \
  die "iOS 16, 17, 18, and 2026 simulator runtimes are not all available"
apple_ios_runtime_plan_supports_deployment_target \
  "$simulator_plan" "$minimum_ios_major" "$minimum_ios_minor" || \
  die "the iOS deployment target $minimum_ios_version cannot run on every required simulator"
chmod 400 "$simulator_plan"
runtime_inventory_hash="$(apple_hardware_sha256 "$runtime_inventory")"
simulator_plan_hash="$(apple_hardware_sha256 "$simulator_plan")"
simulator_count="$(apple_hardware_plan_count "$simulator_plan")"
[ "$simulator_count" -eq 4 ] || die "simulator plan is missing a required release"
printf '%s  %s\n%s  %s\n' \
  "$runtime_inventory_hash" "$(basename "$runtime_inventory")" \
  "$simulator_plan_hash" "$(basename "$simulator_plan")" \
  >"$artifacts/simulator-plan.sha256"
chmod 400 "$artifacts/simulator-plan.sha256"

if ! run_bounded 30 ioreg -r -c IOUSBHostDevice \
    -k SupportsIPhoneOS -l -w 0 >"$usb_ioreg_inventory"; then
  die "physical USB iOS inventory failed"
fi
apple_hardware_write_usb_identifiers \
  "$usb_ioreg_inventory" "$usb_identifiers" || \
  die "physical USB iOS inventory is malformed"
apple_hardware_usb_inventory_is_represented \
  "$inventory" "$usb_identifiers" || \
  die "a physically connected iOS device is unavailable or unauthorized"

apple_hardware_write_inventory_plan \
  "$inventory" "$plan" "$device_skips" \
  "$minimum_ios_major" "$minimum_ios_minor" || \
  die "physical iOS inventory is not eligible for unattended testing"
chmod 400 "$usb_ioreg_inventory" "$usb_identifiers" "$plan" "$device_skips"
inventory_hash="$(apple_hardware_sha256 "$inventory")"
usb_inventory_hash="$(apple_hardware_sha256 "$usb_identifiers")"
plan_hash="$(apple_hardware_sha256 "$plan")"
device_skips_hash="$(apple_hardware_sha256 "$device_skips")"
printf '%s  %s\n%s  %s\n%s  %s\n%s  %s\n' \
  "$inventory_hash" "$(basename "$inventory")" \
  "$usb_inventory_hash" "$(basename "$usb_identifiers")" \
  "$plan_hash" "$(basename "$plan")" \
  "$device_skips_hash" "$(basename "$device_skips")" \
  >"$artifacts/inventory.sha256"
chmod 400 "$artifacts/inventory.sha256"

device_count="$(apple_hardware_plan_count "$plan")"
real_device_matrix="$artifacts/real-device-matrix.md"
apple_hardware_write_real_device_matrix "$plan" "$real_device_matrix" || \
  die "could not write the real-device acceptance matrix"
chmod 400 "$real_device_matrix"
echo "[apple hardware startup] preflighting $device_count attached device(s)"
while IFS= read -r device_id; do
  device_out="$results_root/$device_id"
  mkdir "$device_out"

  details="$device_out/preflight-details.json"
  if ! devicectl_json "$details" "$device_out/preflight-details.log" \
    device info details --device "$device_id" || \
     ! apple_hardware_device_details_are_usable "$details" "$device_id"; then
    die "device $device_id is not physical, paired, booted, in Developer Mode, or DDI-ready"
  fi
  core_device_id="$(apple_hardware_device_details_identifier "$details")" || \
    die "device $device_id has no stable CoreDevice identifier"

  lock_state="$device_out/preflight-lock-state.json"
  if ! devicectl_json "$lock_state" "$device_out/preflight-lock-state.log" \
    device info lockState --device "$device_id" || \
     ! apple_hardware_lock_state_is_unlocked "$lock_state" "$core_device_id"; then
    die "device $device_id is locked or its lock state is unavailable"
  fi

  for bundle_id in network.ur network.ur.networkUITests.xctrunner; do
    safe_bundle="${bundle_id//./-}"
    app_query="$device_out/preflight-${safe_bundle}.json"
    if ! query_installed_app "$device_id" "$bundle_id" "$app_query" \
      "$device_out/preflight-${safe_bundle}.log" || \
       ! apple_hardware_app_query_is_clean "$app_query" "$bundle_id"; then
      die "device $device_id already contains $bundle_id or app state is unavailable"
    fi
  done
  chmod 400 "$device_out"/preflight-*.json
done < <(apple_hardware_plan_ids "$plan")

apple_hardware_inventory_unchanged "$inventory" "$inventory_hash" || \
  die "captured inventory changed before the build"
apple_hardware_inventory_unchanged "$usb_identifiers" "$usb_inventory_hash" || \
  die "captured USB inventory changed before the build"
[ "$(apple_hardware_sha256 "$plan")" = "$plan_hash" ] || \
  die "device plan changed before the build"
[ "$(apple_hardware_sha256 "$device_skips")" = "$device_skips_hash" ] || \
  die "device skip plan changed before the build"

warpctl="$root/warp/warpctl/build/darwin/$host_arch/warpctl"
if [ -n "${WARP_VERSION:-}" ]; then
  sdk_version="$WARP_VERSION"
else
  [ -x "$warpctl" ] || \
    die "local warpctl is missing; run $root/build/all/apple/setup.sh"
  sdk_version="$("$warpctl" ls version)+$("$warpctl" ls version-code)"
fi
case "$sdk_version" in
  ''|*[!A-Za-z0-9.+-]*) die "local SDK version contains unsupported characters" ;;
esac

tools_dir="${UR_ACCEPT_APPLE_TOOLS:-$root/build/all/apple/.acceptance-tools}"
case "$tools_dir" in
  /*) ;;
  *) tools_dir="$root/$tools_dir" ;;
esac
for tool in gomobile gobind checksec; do
  [ -x "$tools_dir/go-bin/$tool" ] || \
    die "$tool is missing; run $root/build/all/apple/setup.sh"
done

echo "[apple hardware startup] building the local Apple SDK"
mkdir -p "$artifacts/sdk-go-cache" "$artifacts/sdk-go-mod-cache"
(
  cd "$root/sdk/build"
  WARP_VERSION="$sdk_version" \
    GOCACHE="$artifacts/sdk-go-cache" \
    GOMODCACHE="$artifacts/sdk-go-mod-cache" \
    GOPATH="$tools_dir/go-path" \
    GOBIN="$tools_dir/go-bin" \
    PATH="$tools_dir/go-bin:$PATH" \
    run_bounded 3600 make build_apple
) 2>&1 | tee "$artifacts/sdk-build.log"
[ -d "$root/sdk/build/apple/URnetworkSdk.xcframework" ] || \
  die "local Apple SDK build produced no app xcframework"
[ -d "$root/sdk/build/apple/URnetworkExtensionSdk.xcframework" ] || \
  die "local Apple SDK build produced no extension xcframework"

nonce="$(openssl rand -hex 16)"
case "$nonce" in ''|*[!0-9a-f]*) die "could not generate the build nonce" ;; esac
[ "${#nonce}" -eq 32 ] || die "could not generate the build nonce"
build_id="hardware-startup-$timestamp"

physical_xctestrun_source=""
if [ "$device_count" -gt 0 ]; then
  echo "[apple iOS devices] building one fresh signed physical-device test bundle"
  set +e
  # Xcode, not the shell, expands $(inherited).
  # shellcheck disable=SC2016
  run_bounded 3600 xcodebuild build-for-testing \
    -jobs 1 \
    -project "$here/app/app.xcodeproj" \
    -scheme URnetwork \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$physical_derived" \
    -configuration Debug \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=6BGU69Q742 \
    URNETWORK_ACCEPTANCE_BUILD_ID="$build_id" \
    URNETWORK_HARDWARE_UI_TEST_NONCE="$nonce" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) URNETWORK_HARDWARE_UI_TESTING' \
    2>&1 | tee "$artifacts/physical-build.log"
  build_status=${PIPESTATUS[0]}
  set -e
  [ "$build_status" -eq 0 ] || die "physical iOS UI-test build failed"

  physical_app_path="$(find "$physical_derived/Build/Products" -type d \
    -name URnetwork.app -not -path '*/PlugIns/*' -print | sort | sed -n '1p')"
  [ "$(find "$physical_derived/Build/Products" -type d -name URnetwork.app \
    -not -path '*/PlugIns/*' -print | wc -l | tr -d ' ')" -eq 1 ] || \
    die "physical iOS build did not produce exactly one app"
  [ -d "$physical_app_path" ] || die "built physical iOS app is missing"
  physical_app_plist="$physical_app_path/Info.plist"
  [ -f "$physical_app_plist" ] || \
    die "built physical iOS Info.plist is missing"
  actual_build_id="$(/usr/libexec/PlistBuddy -c 'Print :URAcceptanceBuildID' "$physical_app_plist" 2>/dev/null || true)"
  actual_nonce="$(/usr/libexec/PlistBuddy -c 'Print :URHardwareUITestNonce' "$physical_app_plist" 2>/dev/null || true)"
  [ "$actual_build_id" = "$build_id" ] || \
    die "built physical app has the wrong provenance marker"
  [ "$actual_nonce" = "$nonce" ] || \
    die "built physical app is not paired to this runner"

  physical_xctestrun_source="$(find "$physical_derived/Build/Products" \
    -maxdepth 1 -type f -name '*.xctestrun' -print | sort | sed -n '1p')"
  [ "$(find "$physical_derived/Build/Products" -maxdepth 1 -type f \
    -name '*.xctestrun' -print | wc -l | tr -d ' ')" -eq 1 ] || \
    die "physical iOS build did not produce exactly one xctestrun file"
  [ -f "$physical_xctestrun_source" ] || \
    die "physical iOS xctestrun file is missing"
else
  echo "[apple iOS devices] no attached eligible physical devices; running the required simulator matrix"
fi

echo "[apple iOS devices] building one fresh simulator no-VPN test bundle"
set +e
# Xcode, not the shell, expands $(inherited).
# shellcheck disable=SC2016
run_bounded 3600 xcodebuild build-for-testing \
  -jobs 1 \
  -project "$here/app/app.xcodeproj" \
  -scheme URnetwork \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$simulator_derived" \
  -configuration Debug \
  URNETWORK_ACCEPTANCE_BUILD_ID="$build_id" \
  URNETWORK_HARDWARE_UI_TEST_NONCE="$nonce" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) URNETWORK_HARDWARE_UI_TESTING' \
  2>&1 | tee "$artifacts/simulator-build.log"
simulator_build_status=${PIPESTATUS[0]}
set -e
[ "$simulator_build_status" -eq 0 ] || die "iOS simulator UI-test build failed"

simulator_app_path="$(find "$simulator_derived/Build/Products" -type d \
  -name URnetwork.app -not -path '*/PlugIns/*' -print | sort | sed -n '1p')"
[ "$(find "$simulator_derived/Build/Products" -type d -name URnetwork.app \
  -not -path '*/PlugIns/*' -print | wc -l | tr -d ' ')" -eq 1 ] || \
  die "simulator build did not produce exactly one app"
[ -d "$simulator_app_path" ] || die "built simulator app is missing"
simulator_app_plist="$simulator_app_path/Info.plist"
[ -f "$simulator_app_plist" ] || die "built simulator Info.plist is missing"
actual_build_id="$(/usr/libexec/PlistBuddy -c 'Print :URAcceptanceBuildID' "$simulator_app_plist" 2>/dev/null || true)"
actual_nonce="$(/usr/libexec/PlistBuddy -c 'Print :URHardwareUITestNonce' "$simulator_app_plist" 2>/dev/null || true)"
[ "$actual_build_id" = "$build_id" ] || \
  die "built simulator app has the wrong provenance marker"
[ "$actual_nonce" = "$nonce" ] || \
  die "built simulator app is not paired to this runner"

simulator_xctestrun_source="$(find "$simulator_derived/Build/Products" \
  -maxdepth 1 -type f -name '*.xctestrun' -print | sort | sed -n '1p')"
[ "$(find "$simulator_derived/Build/Products" -maxdepth 1 -type f \
  -name '*.xctestrun' -print | wc -l | tr -d ' ')" -eq 1 ] || \
  die "simulator build did not produce exactly one xctestrun file"
[ -f "$simulator_xctestrun_source" ] || \
  die "simulator xctestrun file is missing"

overall=0
while IFS= read -r device_id; do
  device_out="$results_root/$device_id"
  echo "[apple hardware startup] testing $device_id"
  apple_hardware_inventory_unchanged "$inventory" "$inventory_hash" || \
    die "captured inventory changed before testing $device_id"
  apple_hardware_inventory_unchanged \
    "$usb_identifiers" "$usb_inventory_hash" || \
    die "captured USB inventory changed before testing $device_id"
  [ "$(apple_hardware_sha256 "$plan")" = "$plan_hash" ] || \
    die "device plan changed before testing $device_id"
  [ "$(apple_hardware_sha256 "$device_skips")" = "$device_skips_hash" ] || \
    die "device skip plan changed before testing $device_id"

  preflight_details="$device_out/preflight-details.json"
  expected_core_device_id="$(
    apple_hardware_device_details_identifier "$preflight_details"
  )" || die "device $device_id lost its preflight identity"
  current_details="$device_out/run-details.json"
  if ! devicectl_json "$current_details" "$device_out/run-details.log" \
    device info details --device "$device_id" || \
     ! apple_hardware_device_details_are_usable "$current_details" "$device_id" || \
     [ "$(apple_hardware_device_details_identifier "$current_details")" != \
       "$expected_core_device_id" ]; then
    apple_hardware_write_result_once \
      "$device_out/status.tsv" "$device_id" FAIL "unusable-before-test"
    overall=1
    continue
  fi

  current_lock="$device_out/run-lock-state.json"
  if ! devicectl_json "$current_lock" "$device_out/run-lock-state.log" \
    device info lockState --device "$device_id" || \
     ! apple_hardware_lock_state_is_unlocked \
       "$current_lock" "$expected_core_device_id"; then
    apple_hardware_write_result_once \
      "$device_out/status.tsv" "$device_id" FAIL "locked-before-test"
    overall=1
    continue
  fi

  app_state_usable=true
  for bundle_id in network.ur network.ur.networkUITests.xctrunner; do
    safe_bundle="${bundle_id//./-}"
    app_query="$device_out/run-${safe_bundle}.json"
    if ! query_installed_app "$device_id" "$bundle_id" "$app_query" \
      "$device_out/run-${safe_bundle}.log" || \
       ! apple_hardware_app_query_is_clean "$app_query" "$bundle_id"; then
      app_state_usable=false
    fi
  done
  if [ "$app_state_usable" != true ]; then
    apple_hardware_write_result_once \
      "$device_out/status.tsv" "$device_id" FAIL "pre-existing-app-before-test"
    overall=1
    continue
  fi

  xctestrun="$(dirname "$physical_xctestrun_source")/hardware-startup-$device_id.xctestrun"
  apple_hardware_prepare_xctestrun \
    "$physical_xctestrun_source" "$xctestrun" "$nonce" "$device_id" || \
    die "could not prepare the paired xctestrun for $device_id"
  apple_hardware_xctestrun_has_paired_no_vpn_contract \
    "$xctestrun" "$nonce" "$device_id" || \
    die "paired no-VPN xctestrun contract is invalid for $device_id"
  chmod 400 "$xctestrun"
  xctestrun_hash="$(apple_hardware_sha256 "$xctestrun")"
  touch "$device_out/.cleanup-required"

  device_test_status=0
  repetition=1
  while [ "$repetition" -le "$repeat_count" ]; do
    echo "[apple hardware startup] $device_id repetition $repetition/$repeat_count"
    apple_hardware_xctestrun_has_paired_no_vpn_contract \
      "$xctestrun" "$nonce" "$device_id" || \
      die "no-VPN unit-test launch contract was lost for $device_id"
    [ "$(apple_hardware_sha256 "$xctestrun")" = "$xctestrun_hash" ] || \
      die "paired xctestrun changed before unit tests for $device_id"
    set +e
    run_bounded 900 xcodebuild test-without-building \
      -jobs 1 \
      -xctestrun "$xctestrun" \
      -destination "platform=iOS,id=$device_id" \
      -derivedDataPath "$physical_derived" \
      -parallel-testing-enabled NO \
      -only-testing:networkTests \
      -resultBundlePath "$device_out/unit-result-$repetition.xcresult" \
      2>&1 | tee "$device_out/unit-test-$repetition.log"
    unit_status=${PIPESTATUS[0]}
    set -e

    apple_hardware_xctestrun_has_paired_no_vpn_contract \
      "$xctestrun" "$nonce" "$device_id" || \
      die "no-VPN UI-test launch contract was lost for $device_id"
    [ "$(apple_hardware_sha256 "$xctestrun")" = "$xctestrun_hash" ] || \
      die "paired xctestrun changed before UI tests for $device_id"
    set +e
    run_bounded 600 xcodebuild test-without-building \
      -jobs 1 \
      -xctestrun "$xctestrun" \
      -destination "platform=iOS,id=$device_id" \
      -derivedDataPath "$physical_derived" \
      -parallel-testing-enabled NO \
      -only-testing:networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess \
      -resultBundlePath "$device_out/result-$repetition.xcresult" \
      2>&1 | tee "$device_out/test-$repetition.log"
    test_status=${PIPESTATUS[0]}
    set -e

    if [ "$unit_status" -ne 0 ] || \
       ! apple_hardware_verify_unit_log \
         "$device_out/unit-test-$repetition.log" || \
       [ "$test_status" -ne 0 ] || \
       ! apple_hardware_verify_test_log \
         "$device_out/test-$repetition.log" "$device_id"; then
      device_test_status=1
      break
    fi
    repetition=$((repetition + 1))
  done

  cleanup_status=0
  if cleanup_device "$device_id"; then
    rm -f "$device_out/.cleanup-required"
  else
    cleanup_status=1
  fi

  if [ "$device_test_status" -eq 0 ] && [ "$cleanup_status" -eq 0 ]; then
    apple_hardware_write_result_once \
      "$device_out/status.tsv" "$device_id" PASS \
      "startup-no-vpn-$repeat_count-repetition(s)"
  else
    apple_hardware_write_result_once \
      "$device_out/status.tsv" "$device_id" FAIL "test-or-cleanup"
    overall=1
  fi
  chmod 400 "$device_out/status.tsv"
done < <(apple_hardware_plan_ids "$plan")

while IFS=$'\t' read -r simulator_lane requested_release runtime_version \
    runtime_identifier device_type_identifier device_type_name; do
  simulator_out="$simulator_results_root/$simulator_lane"
  mkdir "$simulator_out"
  simulator_name="urnetwork-acceptance-ios-${requested_release}-${timestamp}"
  echo "[apple iOS devices] creating $simulator_lane with iOS $runtime_version ($device_type_name)"

  if ! simulator_udid="$(run_bounded 60 xcrun simctl create \
    "$simulator_name" "$device_type_identifier" "$runtime_identifier" \
    2>"$simulator_out/create.log")"; then
    apple_hardware_write_result_once \
      "$simulator_out/status.tsv" "$simulator_lane" FAIL create-failed
    overall=1
    continue
  fi
  if ! apple_ios_simulator_udid_is_valid "$simulator_udid"; then
    apple_hardware_write_result_once \
      "$simulator_out/status.tsv" "$simulator_lane" FAIL malformed-created-udid
    overall=1
    continue
  fi

  active_simulator_lane="$simulator_lane"
  active_simulator_udid="$simulator_udid"
  active_simulator_name="$simulator_name"
  apple_ios_append_owned_simulator \
    "$owned_simulators" "$simulator_lane" "$simulator_udid" \
    "$simulator_name" || \
    die "could not journal the newly created simulator $simulator_udid"
  touch "$simulator_out/.cleanup-required"
  active_simulator_lane=""
  active_simulator_udid=""
  active_simulator_name=""

  jq -n \
    --arg lane "$simulator_lane" \
    --arg requested_release "$requested_release" \
    --arg runtime_version "$runtime_version" \
    --arg runtime_identifier "$runtime_identifier" \
    --arg device_type_identifier "$device_type_identifier" \
    --arg device_type_name "$device_type_name" \
    --arg name "$simulator_name" \
    --arg udid "$simulator_udid" '
      {
        lane: $lane,
        requestedRelease: $requested_release,
        runtimeVersion: $runtime_version,
        runtimeIdentifier: $runtime_identifier,
        deviceTypeIdentifier: $device_type_identifier,
        deviceTypeName: $device_type_name,
        name: $name,
        udid: $udid
      }
    ' >"$simulator_out/identity.json"
  chmod 400 "$simulator_out/identity.json"

  simulator_test_status=0
  if ! run_bounded 60 xcrun simctl boot "$simulator_udid" \
      >"$simulator_out/boot.log" 2>&1 || \
     ! run_bounded 300 xcrun simctl bootstatus "$simulator_udid" -b \
      >"$simulator_out/bootstatus.log" 2>&1 || \
     ! run_bounded 30 xcrun simctl spawn "$simulator_udid" \
      launchctl print system >"$simulator_out/readiness.log" 2>&1; then
    simulator_test_status=1
  fi

  simulator_xctestrun="$(dirname "$simulator_xctestrun_source")/hardware-startup-$simulator_lane-$simulator_udid.xctestrun"
  apple_hardware_prepare_xctestrun \
    "$simulator_xctestrun_source" "$simulator_xctestrun" "$nonce" \
    "$simulator_udid" || \
    die "could not prepare the paired xctestrun for $simulator_lane"
  apple_hardware_xctestrun_has_paired_no_vpn_contract \
    "$simulator_xctestrun" "$nonce" "$simulator_udid" || \
    die "paired no-VPN xctestrun is invalid for $simulator_lane"
  chmod 400 "$simulator_xctestrun"
  simulator_xctestrun_hash="$(apple_hardware_sha256 "$simulator_xctestrun")"

  repetition=1
  while [ "$simulator_test_status" -eq 0 ] && \
      [ "$repetition" -le "$repeat_count" ]; do
    echo "[apple iOS devices] $simulator_lane repetition $repetition/$repeat_count"
    apple_hardware_xctestrun_has_paired_no_vpn_contract \
      "$simulator_xctestrun" "$nonce" "$simulator_udid" || \
      die "no-VPN unit-test contract was lost for $simulator_lane"
    [ "$(apple_hardware_sha256 "$simulator_xctestrun")" = \
      "$simulator_xctestrun_hash" ] || \
      die "paired xctestrun changed before unit tests for $simulator_lane"
    set +e
    run_bounded 900 xcodebuild test-without-building \
      -jobs 1 \
      -xctestrun "$simulator_xctestrun" \
      -destination "platform=iOS Simulator,id=$simulator_udid" \
      -derivedDataPath "$simulator_derived" \
      -parallel-testing-enabled NO \
      -only-testing:networkTests \
      -resultBundlePath "$simulator_out/unit-result-$repetition.xcresult" \
      2>&1 | tee "$simulator_out/unit-test-$repetition.log"
    simulator_unit_status=${PIPESTATUS[0]}
    set -e

    apple_hardware_xctestrun_has_paired_no_vpn_contract \
      "$simulator_xctestrun" "$nonce" "$simulator_udid" || \
      die "no-VPN UI-test contract was lost for $simulator_lane"
    [ "$(apple_hardware_sha256 "$simulator_xctestrun")" = \
      "$simulator_xctestrun_hash" ] || \
      die "paired xctestrun changed before UI tests for $simulator_lane"
    set +e
    run_bounded 600 xcodebuild test-without-building \
      -jobs 1 \
      -xctestrun "$simulator_xctestrun" \
      -destination "platform=iOS Simulator,id=$simulator_udid" \
      -derivedDataPath "$simulator_derived" \
      -parallel-testing-enabled NO \
      -only-testing:networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess \
      -resultBundlePath "$simulator_out/result-$repetition.xcresult" \
      2>&1 | tee "$simulator_out/test-$repetition.log"
    simulator_ui_status=${PIPESTATUS[0]}
    set -e

    if [ "$simulator_unit_status" -ne 0 ] || \
       ! apple_hardware_verify_unit_log \
         "$simulator_out/unit-test-$repetition.log" || \
       [ "$simulator_ui_status" -ne 0 ] || \
       ! apple_hardware_verify_test_log \
         "$simulator_out/test-$repetition.log" "$simulator_udid"; then
      simulator_test_status=1
      break
    fi
    repetition=$((repetition + 1))
  done

  simulator_cleanup_status=0
  if ! apple_ios_cleanup_owned_simulators \
    "$owned_simulators" "$simulator_results_root" \
    "$simulator_out/cleanup-status.tsv"; then
    simulator_cleanup_status=1
  fi

  if [ "$simulator_test_status" -eq 0 ] && \
     [ "$simulator_cleanup_status" -eq 0 ]; then
    apple_hardware_write_result_once \
      "$simulator_out/status.tsv" "$simulator_lane" PASS \
      "startup-no-vpn-ios-$runtime_version-$repeat_count-repetition(s)"
  else
    apple_hardware_write_result_once \
      "$simulator_out/status.tsv" "$simulator_lane" FAIL "test-or-cleanup"
    overall=1
  fi
  chmod 400 "$simulator_out/status.tsv"
done < <(jq -r '.[] | [
  .identifier,
  .requestedRelease,
  .runtimeVersion,
  .runtimeIdentifier,
  .deviceTypeIdentifier,
  .deviceTypeName
] | @tsv' "$simulator_plan")

apple_hardware_results_match_plan "$plan" "$results_root" || \
  die "result set does not match the immutable device plan exactly once"
apple_hardware_results_match_plan \
  "$simulator_plan" "$simulator_results_root" || \
  die "result set does not match the four-lane simulator plan exactly once"
apple_hardware_inventory_unchanged "$inventory" "$inventory_hash" || \
  die "captured inventory changed during the run"
apple_hardware_inventory_unchanged "$usb_identifiers" "$usb_inventory_hash" || \
  die "captured USB inventory changed during the run"
[ "$(apple_hardware_sha256 "$plan")" = "$plan_hash" ] || \
  die "device plan changed during the run"
[ "$(apple_hardware_sha256 "$device_skips")" = "$device_skips_hash" ] || \
  die "device skip plan changed during the run"
[ "$(apple_hardware_sha256 "$runtime_inventory")" = \
  "$runtime_inventory_hash" ] || \
  die "simulator runtime inventory changed during the run"
[ "$(apple_hardware_sha256 "$simulator_plan")" = \
  "$simulator_plan_hash" ] || \
  die "simulator plan changed during the run"

if [ -f "$owned_simulators" ]; then
  apple_ios_validate_owned_simulator_journal "$owned_simulators" || \
    die "owned simulator journal is invalid"
  final_simulator_inventory="$artifacts/simulator-devices-final.json"
  apple_ios_capture_simulator_device_inventory "$final_simulator_inventory" || \
    die "could not capture final simulator cleanup evidence"
  while IFS=$'\t' read -r simulator_lane simulator_udid simulator_name; do
    if apple_ios_simulator_inventory_contains_udid \
      "$final_simulator_inventory" "$simulator_udid"; then
      die "runner-created simulator $simulator_udid remains after cleanup"
    fi
  done <"$owned_simulators"
  chmod 400 "$owned_simulators" "$final_simulator_inventory"
fi

results="$artifacts/results.tsv"
while IFS= read -r device_id; do
  cat "$results_root/$device_id/status.tsv"
done < <(apple_hardware_plan_ids "$plan") >"$results"
while IFS= read -r simulator_lane; do
  cat "$simulator_results_root/$simulator_lane/status.tsv"
done < <(apple_hardware_plan_ids "$simulator_plan") >>"$results"
chmod 400 "$results"

exit "$overall"
