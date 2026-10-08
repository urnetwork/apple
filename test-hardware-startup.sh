#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Deterministic, no-VPN startup regression on disposable simulators for
# iOS 17, 18, 2026 (iOS 26), and 27. Physical iPhones are outside this matrix.
# This lane never runs account, tunnel, VPN, peer, or data-plane cases.
#
# Usage:
#   ./test-hardware-startup.sh
#   ./test-hardware-startup.sh --defer-ios-17-2  (explicit user authorization only)
#
# Environment:
#   UR_ACCEPT_REPEAT=N  Run both deterministic corpora N times per release.
#
# The simulator inventory is captured into an immutable four-release plan.
# The only temporary coverage exception is an explicit iOS 17.2 deferral;
# it is recorded as tailored coverage, never a full four-release pass.
# There are no device or test selectors or implicit environment exclusions.
# Missing simulator runtimes are installed automatically.
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
root="${URNETWORK_ROOT:-$(dirname "$here")}"
source "$here/test-hardware-startup-lib.sh"
result_matrix="${UR_ACCEPT_RESULT_FILE:-}"
repeat_count="${UR_ACCEPT_REPEAT:-1}"
defer_ios_17_2=0
expected_simulator_count=4

if [ "$#" -ne 0 ]; then
  case "${1:-}" in
    --defer-ios-17-2)
      [ "$#" -eq 1 ] || { echo "unexpected iOS startup arguments" >&2; exit 2; }
      defer_ios_17_2=1
      expected_simulator_count=3
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[apple hardware startup] unknown arguments; this lane has no selectors" >&2; exit 2 ;;
  esac
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

for command_name in go jq lipo make openssl shasum timeout xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "required command is missing: $command_name"
done
[ "$(uname -s)" = Darwin ] || die "iOS simulator startup tests require macOS"
network_test_gate="$root/tests/network-intensive-suite-lock.sh"
[ -x "$network_test_gate" ] || {
  echo "[apple hardware startup] network-intensive suite gate is missing: $network_test_gate" >&2
  exit 127
}
if [ "${URNETWORK_NETWORK_TEST_LOCK_HELD:-}" != 1 ]; then
  exec "$network_test_gate" main-acceptance apple-ios-device-startup -- \
    "$here/test-hardware-startup.sh" "$@"
fi
if ! "$network_test_gate" --verify-held main-acceptance; then
  echo "[apple hardware startup] inherited suite-gate ownership is invalid" >&2
  exit 70
fi

acceptance_root="$here/tests/__hardware_startup__"
mkdir -p "$acceptance_root"

timestamp="$(date -u +%Y%m%d-%H%M%SZ)"
artifacts="$acceptance_root/$timestamp"
mkdir "$artifacts" || die "artifact directory already exists: $artifacts"
runtime_inventory_before="$artifacts/simulator-runtimes-before.json"
runtime_inventory="$artifacts/simulator-runtimes.json"
runtime_download_logs="$artifacts/simulator-runtime-downloads"
simulator_plan="$artifacts/simulator-plan.json"
simulator_results_root="$artifacts/simulators"
owned_simulators="$artifacts/owned-simulators.tsv"
simulator_derived="$artifacts/DerivedData-simulator"
mkdir "$runtime_download_logs" "$simulator_results_root"
if [ "$defer_ios_17_2" -eq 1 ]; then
  printf '%s\n' '{"coverage_scope":"tailored-ios17.2-deferred","deferred":["ios-17/17.2"],"required":["ios-18","ios-2026","ios-27"]}' >"$artifacts/simulator-coverage.json"
  echo "[apple iOS simulators] TAILORED coverage: ios-17 (pinned iOS 17.2) explicitly DEFERRED"
else
  printf '%s\n' '{"coverage_scope":"full","deferred":[],"required":["ios-17","ios-18","ios-2026","ios-27"]}' >"$artifacts/simulator-coverage.json"
fi
chmod 400 "$artifacts/simulator-coverage.json"

simulator_count=0
active_simulator_lane=""
active_simulator_udid=""
active_simulator_name=""

run_bounded() {
  timeout --foreground "$@"
}

# Invoked indirectly by the EXIT/INT/TERM traps installed below.
# shellcheck disable=SC2329
cleanup() {
  local exit_status=$? trap_cleanup_log
  trap - EXIT INT TERM
  set +e

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
      echo "[apple iOS simulators] could not journal active simulator $active_simulator_udid; leaving it in place" >&2
      exit_status=1
    fi
  fi
  if [ -f "$owned_simulators" ] && \
     [ -n "$(find "$simulator_results_root" -name .cleanup-required -type f -print -quit)" ]; then
    trap_cleanup_log="$artifacts/simulator-trap-cleanup.tsv"
    if ! apple_ios_cleanup_owned_simulators \
      "$owned_simulators" "$simulator_results_root" "$trap_cleanup_log"; then
      echo "[apple iOS simulators] one or more disposable simulators could not be removed" >&2
      exit_status=1
    fi
  fi

  # The combined runner seals this receipt with the MAIN logs. Publish only
  # after the selected tests and owned-simulator cleanup have both succeeded.
  if [ "$exit_status" -eq 0 ] && [ "$defer_ios_17_2" -eq 1 ] && \
     [ -n "${URNETWORK_RUNNER_MAIN_COVERAGE_FILE:-}" ]; then
    if ! (set -C; jq \
      --arg run_id "${URNETWORK_RUN_ID:-}" \
      --arg plan_sha256 "${URNETWORK_PLAN_SHA256:-}" \
      --arg runtime_plan_sha256 "$simulator_plan_hash" \
      '. + {version: 1, run_id: $run_id, plan_sha256: $plan_sha256,
        runtime_plan_sha256: $runtime_plan_sha256, passed: true, cleanup_complete: true}' \
      "$artifacts/simulator-coverage.json" >"$URNETWORK_RUNNER_MAIN_COVERAGE_FILE"); then
      echo "[apple iOS simulators] could not publish the runner-owned tailored coverage receipt" >&2
      exit_status=1
    fi
  fi

  if [ -n "$result_matrix" ]; then
    mkdir -p "$(dirname "$result_matrix")"
    if [ "$exit_status" -eq 0 ]; then
      if [ "$defer_ios_17_2" -eq 1 ]; then
        printf 'apple\thardware-startup-no-vpn\tPASS\t3 selected lanes passed; TAILORED coverage; ios-17/17.2 DEFERRED, not full four-release coverage\n' >>"$result_matrix"
      else
        printf 'apple\thardware-startup-no-vpn\tPASS\t%s required simulator lane(s) passed\n' \
          "$simulator_count" >>"$result_matrix"
      fi
    else
      printf 'apple\thardware-startup-no-vpn\tFAIL\tiOS simulator no-VPN startup failed; see Apple simulator artifacts\n' \
        >>"$result_matrix"
    fi
    chmod 600 "$result_matrix"
  fi

  if [ "$exit_status" -eq 0 ]; then
    if [ "$defer_ios_17_2" -eq 1 ]; then
      echo "[apple iOS simulators] ✓ PASS_TAILORED: iOS 17.2 DEFERRED (artifacts: $artifacts)"
    else
      echo "[apple iOS simulators] ✓ PASSED (artifacts: $artifacts)"
    fi
  else
    echo "[apple iOS simulators] ✗ FAILED (artifacts: $artifacts)" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! minimum_ios_version="$({
    run_bounded 120 xcodebuild \
      -project "$here/app/app.xcodeproj" \
      -target networkUITests \
      -configuration Debug \
      -sdk iphonesimulator \
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
  *) die "iOS simulator startup requires an arm64 host for the local Apple SDK" ;;
esac

# These compile the actual profile gateway/controller against counting fakes,
# then typecheck against Apple's SDK. They use no simulator or profile service.
# Canonical runs always test this source tree with the normal compiler arm.
echo "[apple iOS simulators] verifying native profile invariants"
if ! run_bounded 360 env \
  -u UR_PROFILE_BOUNDARY_SOURCE_ROOT \
  -u UR_DEVICE_GENERATION_SOURCE_ROOT \
  -u UR_DEVICE_GENERATION_SANITIZER \
  GOMAXPROCS=2 go test -p 1 -parallel 1 -count=1 \
  "$here/test-vpn-profile-system_test.go" \
  "$here/test-split-tunnel-device-generation_test.go" \
  >"$artifacts/profile-boundary-test.log" 2>&1; then
  tail -n 40 "$artifacts/profile-boundary-test.log" >&2
  die "native profile invariants failed"
fi

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

echo "[apple iOS simulators] ensuring $expected_simulator_count selected simulator runtimes (iOS 17.2 deferred=$defer_ios_17_2)"
capture_runtime_inventory "$runtime_inventory_before" || \
  die "could not inventory installed iOS simulator runtimes"
apple_ios_download_missing_simulator_runtimes \
  "$runtime_inventory_before" "$runtime_download_logs" \
  "$runtime_architecture" "$defer_ios_17_2" || \
  die "could not install every required iOS simulator runtime"
capture_runtime_inventory "$runtime_inventory" || \
  die "could not inventory iOS simulator runtimes after provisioning"
apple_ios_write_simulator_runtime_plan \
  "$runtime_inventory" "$simulator_plan" "$defer_ios_17_2" || \
  die "not every selected iOS simulator runtime is available"
apple_ios_runtime_plan_supports_deployment_target \
  "$simulator_plan" "$minimum_ios_major" "$minimum_ios_minor" "$defer_ios_17_2" || \
  die "the iOS deployment target $minimum_ios_version cannot run on every required simulator"
chmod 400 "$simulator_plan"
runtime_inventory_hash="$(apple_hardware_sha256 "$runtime_inventory")"
simulator_plan_hash="$(apple_hardware_sha256 "$simulator_plan")"
simulator_count="$(apple_hardware_plan_count "$simulator_plan")"
[ "$simulator_count" -eq "$expected_simulator_count" ] || die "simulator plan is missing a required release"
printf '%s  %s\n%s  %s\n' \
  "$runtime_inventory_hash" "$(basename "$runtime_inventory")" \
  "$simulator_plan_hash" "$(basename "$simulator_plan")" \
  >"$artifacts/simulator-plan.sha256"
chmod 400 "$artifacts/simulator-plan.sha256"

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
# The local SDK intentionally ships arm64-only iOS simulator slices. A generic
# Xcode destination otherwise also requests x86_64, even on this arm64 host.
for sdk_framework in URnetworkSdk URnetworkExtensionSdk; do
  simulator_sdk_binary="$root/sdk/build/apple/$sdk_framework.xcframework/ios-arm64-simulator/$sdk_framework.framework/$sdk_framework"
  if [ ! -f "$simulator_sdk_binary" ] || \
     ! run_bounded 60 lipo -verify_arch arm64 "$simulator_sdk_binary" \
       >>"$artifacts/simulator-sdk-architectures.log" 2>&1; then
    die "local Apple SDK has no usable arm64 simulator binary: $sdk_framework"
  fi
done

nonce="$(openssl rand -hex 16)"
case "$nonce" in ''|*[!0-9a-f]*) die "could not generate the build nonce" ;; esac
[ "${#nonce}" -eq 32 ] || die "could not generate the build nonce"
build_id="hardware-startup-$timestamp"

echo "[apple iOS simulators] building one fresh simulator no-VPN test bundle"
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
  ARCHS=arm64 \
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
while IFS=$'\t' read -r simulator_lane requested_release runtime_version \
    runtime_identifier device_type_identifier device_type_name; do
  simulator_out="$simulator_results_root/$simulator_lane"
  mkdir "$simulator_out"
  # The runtime still owns one result row. Its immutable identity now lists
  # the separate process owners rather than naming one reused simulator.
  jq -n \
    --arg lane "$simulator_lane" \
    --arg requested_release "$requested_release" \
    --arg runtime_version "$runtime_version" \
    --arg runtime_identifier "$runtime_identifier" \
    --arg device_type_identifier "$device_type_identifier" \
    --arg device_type_name "$device_type_name" \
    --argjson repeat_count "$repeat_count" '
      {
        version: 2, lane: $lane,
        requestedRelease: $requested_release,
        runtimeVersion: $runtime_version,
        runtimeIdentifier: $runtime_identifier,
        deviceTypeIdentifier: $device_type_identifier,
        deviceTypeName: $device_type_name,
        owners: [range(1; $repeat_count + 1) as $repetition
          | ["unit", "ui"][] as $corpus
          | $lane + "-" + $corpus + "-" + ($repetition | tostring)]
      }
    ' >"$simulator_out/identity.json"
  chmod 400 "$simulator_out/identity.json"
  simulator_test_status=0
  repetition=1
  while [ "$simulator_test_status" -eq 0 ] && \
      [ "$repetition" -le "$repeat_count" ]; do
    echo "[apple iOS simulators] $simulator_lane repetition $repetition/$repeat_count"
    # Returning from xcodebuild joins its test process, not the widget work
    # owned by that installed app. The next action reinstalls the app and
    # can invalidate a pending extension launch. Own a fresh simulator for
    # each action, and join/delete it before any subsequent installation.
    for simulator_corpus in unit ui; do
      simulator_owner="$simulator_lane-$simulator_corpus-$repetition"
      simulator_owner_out="$simulator_results_root/$simulator_owner"
      mkdir "$simulator_owner_out"
      simulator_name="urnetwork-acceptance-${simulator_owner}-${timestamp}"
      echo "[apple iOS simulators] creating $simulator_owner with iOS $runtime_version ($device_type_name)"
      if ! simulator_udid="$(run_bounded 60 xcrun simctl create \
        "$simulator_name" "$device_type_identifier" "$runtime_identifier" \
        2>"$simulator_owner_out/create.log")"; then
        apple_hardware_write_result_once \
          "$simulator_owner_out/action-status.tsv" "$simulator_owner" FAIL create-failed
        simulator_test_status=1
        continue
      fi
      if ! apple_ios_simulator_udid_is_valid "$simulator_udid"; then
        apple_hardware_write_result_once \
          "$simulator_owner_out/action-status.tsv" "$simulator_owner" FAIL malformed-created-udid
        simulator_test_status=1
        continue
      fi

      active_simulator_lane="$simulator_owner"
      active_simulator_udid="$simulator_udid"
      active_simulator_name="$simulator_name"
      apple_ios_append_owned_simulator \
        "$owned_simulators" "$simulator_owner" "$simulator_udid" \
        "$simulator_name" || \
        die "could not journal the newly created simulator $simulator_udid"
      touch "$simulator_owner_out/.cleanup-required"
      active_simulator_lane=""
      active_simulator_udid=""
      active_simulator_name=""

      jq -n \
        --arg lane "$simulator_lane" \
        --arg owner "$simulator_owner" \
        --arg corpus "$simulator_corpus" \
        --argjson repetition "$repetition" \
        --arg requested_release "$requested_release" \
        --arg runtime_version "$runtime_version" \
        --arg runtime_identifier "$runtime_identifier" \
        --arg device_type_identifier "$device_type_identifier" \
        --arg device_type_name "$device_type_name" \
        --arg name "$simulator_name" \
        --arg udid "$simulator_udid" '
          {
            lane: $lane, owner: $owner, corpus: $corpus, repetition: $repetition,
            requestedRelease: $requested_release,
            runtimeVersion: $runtime_version,
            runtimeIdentifier: $runtime_identifier,
            deviceTypeIdentifier: $device_type_identifier,
            deviceTypeName: $device_type_name,
            name: $name,
            udid: $udid
          }
        ' >"$simulator_owner_out/identity.json"
      chmod 400 "$simulator_owner_out/identity.json"

      simulator_action_status=0
      if ! run_bounded 60 xcrun simctl boot "$simulator_udid" \
          >"$simulator_owner_out/boot.log" 2>&1 || \
         ! run_bounded 300 xcrun simctl bootstatus "$simulator_udid" -b \
          >"$simulator_owner_out/bootstatus.log" 2>&1 || \
         ! run_bounded 30 xcrun simctl spawn "$simulator_udid" \
          launchctl print system >"$simulator_owner_out/readiness.log" 2>&1; then
        simulator_action_status=1
      fi

      if [ "$simulator_action_status" -eq 0 ]; then
        simulator_xctestrun="$(dirname "$simulator_xctestrun_source")/hardware-startup-$simulator_owner-$simulator_udid.xctestrun"
        apple_hardware_prepare_xctestrun \
          "$simulator_xctestrun_source" "$simulator_xctestrun" "$nonce" \
          "$simulator_udid" || \
          die "could not prepare the paired xctestrun for $simulator_owner"
        apple_hardware_xctestrun_has_paired_no_vpn_contract \
          "$simulator_xctestrun" "$nonce" "$simulator_udid" || \
          die "paired no-VPN xctestrun is invalid for $simulator_owner"
        chmod 400 "$simulator_xctestrun"
        simulator_xctestrun_hash="$(apple_hardware_sha256 "$simulator_xctestrun")"

        apple_hardware_xctestrun_has_paired_no_vpn_contract \
          "$simulator_xctestrun" "$nonce" "$simulator_udid" || \
          die "no-VPN test contract was lost for $simulator_owner"
        [ "$(apple_hardware_sha256 "$simulator_xctestrun")" = \
          "$simulator_xctestrun_hash" ] || \
          die "paired xctestrun changed before tests for $simulator_owner"
        set +e
        if [ "$simulator_corpus" = unit ]; then
          run_bounded 900 xcodebuild test-without-building \
            -jobs 1 \
            -xctestrun "$simulator_xctestrun" \
            -destination "platform=iOS Simulator,id=$simulator_udid" \
            -derivedDataPath "$simulator_derived" \
            -parallel-testing-enabled NO \
            -only-testing:networkTests \
            -resultBundlePath "$simulator_out/unit-result-$repetition.xcresult" \
            2>&1 | tee "$simulator_out/unit-test-$repetition.log"
          simulator_action_status=${PIPESTATUS[0]}
          apple_hardware_verify_unit_log \
            "$simulator_out/unit-test-$repetition.log" || simulator_action_status=1
        else
          run_bounded 600 xcodebuild test-without-building \
            -jobs 1 \
            -xctestrun "$simulator_xctestrun" \
            -destination "platform=iOS Simulator,id=$simulator_udid" \
            -derivedDataPath "$simulator_derived" \
            -parallel-testing-enabled NO \
            -only-testing:networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess \
            -resultBundlePath "$simulator_out/result-$repetition.xcresult" \
            2>&1 | tee "$simulator_out/test-$repetition.log"
          simulator_action_status=${PIPESTATUS[0]}
          apple_hardware_verify_test_log \
            "$simulator_out/test-$repetition.log" "$simulator_udid" || simulator_action_status=1
        fi
        set -e
      fi

      simulator_cleanup_status=0
      if ! apple_ios_cleanup_owned_simulators \
        "$owned_simulators" "$simulator_results_root" \
        "$simulator_owner_out/cleanup-status.tsv"; then
        simulator_cleanup_status=1
      fi
      if [ "$simulator_action_status" -eq 0 ] && \
         [ "$simulator_cleanup_status" -eq 0 ]; then
        apple_hardware_write_result_once \
          "$simulator_owner_out/action-status.tsv" "$simulator_owner" PASS tested-and-deleted
      else
        apple_hardware_write_result_once \
          "$simulator_owner_out/action-status.tsv" "$simulator_owner" FAIL test-or-cleanup
        simulator_test_status=1
      fi
      chmod 400 "$simulator_owner_out/action-status.tsv"
      if [ "$simulator_cleanup_status" -ne 0 ]; then
        apple_hardware_write_result_once \
          "$simulator_out/status.tsv" "$simulator_lane" FAIL owned-simulator-cleanup
        chmod 400 "$simulator_out/status.tsv"
        die "could not join and remove $simulator_owner; no later action may install"
      fi
    done
    repetition=$((repetition + 1))
  done

  if [ "$simulator_test_status" -eq 0 ]; then
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

apple_hardware_results_match_plan \
  "$simulator_plan" "$simulator_results_root" || \
  die "result set does not match the selected simulator plan exactly once"
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
while IFS= read -r simulator_lane; do
  cat "$simulator_results_root/$simulator_lane/status.tsv"
done < <(apple_hardware_plan_ids "$simulator_plan") >"$results"
chmod 400 "$results"

exit "$overall"
