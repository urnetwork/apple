#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/test-hardware-startup-lib.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-hardware-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

runtime_inventory="$test_root/runtime-inventory.json"
runtime_plan="$test_root/runtime-plan.json"
cat >"$runtime_inventory" <<'JSON'
{
  "runtimes": [
    {
      "platform": "iOS",
      "version": "16.2",
      "buildversion": "20C52",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-2",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 14",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "16.4",
      "buildversion": "20E247",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-4",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 14 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "17.5",
      "buildversion": "21F79",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 15 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "17.6",
      "buildversion": "21G80",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-6",
      "isAvailable": false,
      "supportedDeviceTypes": []
    },
    {
      "platform": "iOS",
      "version": "18.5",
      "buildversion": "22F77",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 16 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "26.4.1",
      "buildversion": "23E254a",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 17 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "26.5",
      "buildversion": "23F77",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 17 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        }
      ]
    },
    {
      "platform": "iOS",
      "version": "27.0",
      "buildversion": "24A434",
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "isAvailable": true,
      "supportedDeviceTypes": [
        {
          "productFamily": "iPhone",
          "name": "iPhone 17 Pro",
          "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        }
      ]
    },
    {
      "platform": "tvOS",
      "version": "26.5",
      "buildversion": "23L470",
      "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-5",
      "isAvailable": true,
      "supportedDeviceTypes": []
    }
  ]
}
JSON

[ "$(apple_ios_required_simulator_releases)" = \
  $'ios-17\t17\t17.2\nios-18\t18\t18.5\nios-2026\t26\t26.5\nios-27\t27\t27.0' ] || {
  echo "the required iOS simulator release matrix changed" >&2
  exit 1
}
apple_ios_write_simulator_runtime_plan "$runtime_inventory" "$runtime_plan"
[ "$(apple_hardware_plan_count "$runtime_plan")" -eq 4 ]
[ "$(apple_hardware_plan_ids "$runtime_plan" | paste -sd, -)" = \
  "ios-17,ios-18,ios-2026,ios-27" ] || {
  echo "the simulator runtime plan omitted or reordered a required lane" >&2
  exit 1
}
[ "$(jq -r 'map(.runtimeVersion) | join(",")' "$runtime_plan")" = \
  "17.5,18.5,26.5,27.0" ] || {
  echo "the simulator runtime plan did not select the newest installed patch" >&2
  exit 1
}
[ "$(jq -r '.[0].deviceTypeIdentifier' "$runtime_plan")" = \
  com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro ] || {
  echo "the simulator plan did not preserve a compatible iPhone type" >&2
  exit 1
}
apple_ios_runtime_plan_supports_deployment_target "$runtime_plan" 16 0
apple_ios_runtime_plan_supports_deployment_target "$runtime_plan" 17 5
if apple_ios_runtime_plan_supports_deployment_target \
  "$runtime_plan" 17 6; then
  echo "an iOS 17.5 runtime accepted an iOS 17.6 deployment target" >&2
  exit 1
fi
[ -z "$(apple_ios_missing_simulator_downloads "$runtime_inventory")" ] || {
  echo "an already complete runtime inventory requested a download" >&2
  exit 1
}

jq '.runtimes |= map(select(.version | startswith("16.") | not))' \
  "$runtime_inventory" >"$test_root/runtime-without-16.json"
[ -z "$(apple_ios_missing_simulator_downloads "$test_root/runtime-without-16.json")" ] || {
  echo "the runner requested an obsolete iOS 16 simulator download" >&2
  exit 1
}
apple_ios_write_simulator_runtime_plan \
  "$test_root/runtime-without-16.json" "$test_root/runtime-without-16-plan.json"
cmp "$runtime_plan" "$test_root/runtime-without-16-plan.json"

while IFS=$'\t' read -r missing_lane missing_major pinned_download; do
  jq --arg major "$missing_major" \
    '.runtimes |= map(select(.platform != "iOS" or (.version | split(".")[0]) != $major))' \
    "$runtime_inventory" >"$test_root/runtime-missing-$missing_major.json"
  [ "$(apple_ios_missing_simulator_downloads \
    "$test_root/runtime-missing-$missing_major.json")" = \
    "$missing_lane"$'\t'"$missing_major"$'\t'"$pinned_download" ] || {
    echo "the missing iOS $missing_major runtime did not select its pinned download" >&2
    exit 1
  }
  if apple_ios_write_simulator_runtime_plan \
    "$test_root/runtime-missing-$missing_major.json" \
    "$test_root/runtime-missing-$missing_major-plan.json" 2>/dev/null; then
    echo "an incomplete simulator runtime inventory produced a runnable plan" >&2
    exit 1
  fi
  [ ! -e "$test_root/runtime-missing-$missing_major-plan.json" ] || {
    echo "a rejected simulator runtime inventory left an authoritative plan" >&2
    exit 1
  }
done <<'RELEASES'
ios-17	17	17.2
ios-18	18	18.5
ios-2026	26	26.5
ios-27	27	27.0
RELEASES

simulator_results="$test_root/required-simulator-results"
for required_lane in ios-17 ios-18 ios-2026 ios-27; do
  mkdir -p "$simulator_results/$required_lane"
  apple_hardware_write_result_once \
    "$simulator_results/$required_lane/status.tsv" "$required_lane" PASS startup-no-vpn
done
apple_hardware_results_match_plan "$runtime_plan" "$simulator_results"
mv "$simulator_results/ios-27/status.tsv" "$test_root/ios-27-status.tsv"
if apple_hardware_results_match_plan "$runtime_plan" "$simulator_results"; then
  echo "a missing iOS 27 result silently passed the simulator matrix" >&2
  exit 1
fi
printf 'ios-27\tSKIP\truntime-unavailable\n' >"$simulator_results/ios-27/status.tsv"
if apple_hardware_results_match_plan "$runtime_plan" "$simulator_results"; then
  echo "a skipped iOS 27 result silently passed the simulator matrix" >&2
  exit 1
fi
mv "$test_root/ios-27-status.tsv" "$simulator_results/ios-27/status.tsv"
apple_hardware_results_match_plan "$runtime_plan" "$simulator_results"
if apple_hardware_write_result_once \
  "$simulator_results/ios-27/status.tsv" ios-27 PASS duplicate 2>/dev/null; then
  echo "a simulator result was overwritten" >&2
  exit 1
fi
mkdir "$simulator_results/unplanned"
printf 'unplanned\tPASS\tunowned-result\n' >"$simulator_results/unplanned/status.tsv"
if apple_hardware_results_match_plan "$runtime_plan" "$simulator_results"; then
  echo "an unplanned result silently passed the simulator matrix" >&2
  exit 1
fi
rm "$simulator_results/unplanned/status.tsv"

jq '(.runtimes[] | select(.version == "18.5").supportedDeviceTypes) = []' \
  "$runtime_inventory" >"$test_root/runtime-no-iphone.json"
if apple_ios_write_simulator_runtime_plan \
  "$test_root/runtime-no-iphone.json" \
  "$test_root/runtime-no-iphone-plan.json" 2>/dev/null; then
  echo "a simulator runtime without a compatible iPhone entered the plan" >&2
  exit 1
fi

jq '(.runtimes[] | select(.version == "18.5").identifier) = "unsafe runtime"' \
  "$runtime_inventory" >"$test_root/runtime-unsafe.json"
if apple_ios_write_simulator_runtime_plan \
  "$test_root/runtime-unsafe.json" \
  "$test_root/runtime-unsafe-plan.json" 2>/dev/null; then
  echo "an unsafe simulator runtime identifier entered the plan" >&2
  exit 1
fi

owned_journal="$test_root/owned-simulators.tsv"
if apple_ios_simulator_lane_is_valid ios-16; then
  echo "the removed iOS 16 simulator lane remains eligible for ownership" >&2
  exit 1
fi
apple_ios_append_owned_simulator \
  "$owned_journal" ios-27 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-27-20260905-120000Z
apple_ios_append_owned_simulator \
  "$owned_journal" ios-17 11111111-2222-3333-4444-555555555555 \
  urnetwork-acceptance-ios-17-20260905-120000Z
apple_ios_validate_owned_simulator_journal "$owned_journal"
apple_ios_owned_simulator_journal_has_identity \
  "$owned_journal" ios-27 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-27-20260905-120000Z
if apple_ios_owned_simulator_journal_has_identity \
  "$owned_journal" ios-27 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-27-20260905-120001Z; then
  echo "a mismatched active simulator was treated as already journaled" >&2
  exit 1
fi
if apple_ios_append_owned_simulator \
  "$owned_journal" ios-17 99999999-2222-3333-4444-555555555555 \
  urnetwork-acceptance-ios-17-20260905-120000Z 2>/dev/null; then
  echo "a duplicate simulator lane entered the ownership journal" >&2
  exit 1
fi
if apple_ios_append_owned_simulator \
  "$owned_journal" ios-18 not-a-udid \
  urnetwork-acceptance-ios-18-20260905-120000Z 2>/dev/null; then
  echo "a malformed simulator UDID entered the ownership journal" >&2
  exit 1
fi
printf 'ios-18\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\twrong-prefix\n' \
  >"$test_root/owned-malformed.tsv"
if apple_ios_validate_owned_simulator_journal \
  "$test_root/owned-malformed.tsv" 2>/dev/null; then
  echo "a simulator with an unowned name passed journal validation" >&2
  exit 1
fi

mkdir "$test_root/fake-bin" "$test_root/runtime-download-logs"
cat >"$test_root/fake-bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$APPLE_TEST_XCODEBUILD_CALLS"
case "$*" in *-architectureVariant*) exit 9 ;; esac
SH
chmod 700 "$test_root/fake-bin/xcodebuild"
: >"$test_root/xcodebuild-calls.txt"
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_XCODEBUILD_CALLS="$test_root/xcodebuild-calls.txt" \
  apple_ios_download_missing_simulator_runtimes \
    "$test_root/runtime-missing-17.json" \
    "$test_root/runtime-download-logs" default
[ "$(cat "$test_root/xcodebuild-calls.txt")" = \
  '-downloadPlatform iOS -buildVersion 17.2' ] || {
  echo "runtime provisioning did not download exactly the missing iOS major" >&2
  exit 1
}
[ -f "$test_root/runtime-download-logs/ios-17-download.log" ] || {
  echo "runtime provisioning did not preserve its download log" >&2
  exit 1
}
mkdir "$test_root/runtime-download-27-logs"
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_XCODEBUILD_CALLS="$test_root/xcodebuild-27-calls.txt" \
  apple_ios_download_missing_simulator_runtimes \
    "$test_root/runtime-missing-27.json" \
    "$test_root/runtime-download-27-logs" default
[ "$(cat "$test_root/xcodebuild-27-calls.txt")" = \
  '-downloadPlatform iOS -buildVersion 27.0' ] && \
  [ -f "$test_root/runtime-download-27-logs/ios-27-download.log" ] || {
  echo "runtime provisioning did not preserve the required iOS 27 download" >&2
  exit 1
}

# A process substitution used to discard the inventory parser's failure: the
# download loop saw EOF and returned success without validating any runtime.
printf '{"runtimes":null}\n' >"$test_root/runtime-malformed.json"
for rejected_inventory in "$test_root/runtime-malformed.json" \
    "$test_root/runtime-does-not-exist.json"; do
  mkdir "$test_root/rejected-runtime-download-logs"
  if PATH="$test_root/fake-bin:$PATH" \
    APPLE_TEST_XCODEBUILD_CALLS="$test_root/xcodebuild-calls.txt" \
    apple_ios_download_missing_simulator_runtimes \
      "$rejected_inventory" "$test_root/rejected-runtime-download-logs" \
      default 2>/dev/null; then
    echo "invalid runtime inventory incorrectly reported successful provisioning" >&2
    exit 1
  fi
  [ "$(wc -l <"$test_root/xcodebuild-calls.txt" | tr -d ' ')" = 1 ] || {
    echo "invalid runtime inventory started an xcodebuild download" >&2
    exit 1
  }
  rmdir "$test_root/rejected-runtime-download-logs"
done

cat >"$test_root/fake-bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = simctl ] || exit 2
shift
printf '%s\n' "$*" >>"$APPLE_TEST_SIMCTL_CALLS"
case "${1:-} ${2:-} ${3:-}" in
  'list devices --json')
    if [ "$(cat "$APPLE_TEST_SIM_STATE")" = present ]; then
      cat <<JSON
{"devices":{"runtime":[
  {"udid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"urnetwork-acceptance-ios-27-20260905-120000Z","state":"Booted","isAvailable":true},
  {"udid":"99999999-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"pre-existing-user-simulator","state":"Booted","isAvailable":true}
]}}
JSON
    else
      cat <<JSON
{"devices":{"runtime":[
  {"udid":"99999999-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"pre-existing-user-simulator","state":"Booted","isAvailable":true}
]}}
JSON
    fi
    ;;
  shutdown*) ;;
  delete*)
    [ "${2:-}" = AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE ] || exit 9
    [ "${APPLE_TEST_DELETE_FAIL:-0}" = 0 ] || exit 8
    printf 'deleted\n' >"$APPLE_TEST_SIM_STATE"
    ;;
  *) exit 3 ;;
esac
SH
chmod 700 "$test_root/fake-bin/xcrun"

cleanup_journal="$test_root/cleanup-owned.tsv"
apple_ios_append_owned_simulator \
  "$cleanup_journal" ios-27 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-27-20260905-120000Z
mkdir -p "$test_root/simulator-results/ios-27"
touch "$test_root/simulator-results/ios-27/.cleanup-required"
printf 'present\n' >"$test_root/simulator-state"
: >"$test_root/simctl-calls.txt"
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_SIMCTL_CALLS="$test_root/simctl-calls.txt" \
APPLE_TEST_SIM_STATE="$test_root/simulator-state" \
  apple_ios_cleanup_owned_simulators \
    "$cleanup_journal" "$test_root/simulator-results" \
    "$test_root/simulator-cleanup.tsv"
[ ! -e "$test_root/simulator-results/ios-27/.cleanup-required" ] || {
  echo "successful simulator deletion left cleanup armed" >&2
  exit 1
}
[ "$(cat "$test_root/simulator-cleanup.tsv")" = \
  $'ios-27\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tPASS\tshutdown-and-deleted' ] || {
  echo "simulator cleanup did not preserve exact success evidence" >&2
  exit 1
}
[ "$(grep -cF 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' \
  "$test_root/simctl-calls.txt")" -eq 2 ] || {
  echo "simulator cleanup did not target the owned UDID exactly" >&2
  exit 1
}
if grep -qF 99999999-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  "$test_root/simctl-calls.txt"; then
  echo "simulator cleanup touched a pre-existing user simulator" >&2
  exit 1
fi

mkdir -p "$test_root/simulator-results-failed/ios-27"
touch "$test_root/simulator-results-failed/ios-27/.cleanup-required"
printf 'present\n' >"$test_root/simulator-state"
: >"$test_root/simctl-calls-failed.txt"
if PATH="$test_root/fake-bin:$PATH" \
  APPLE_TEST_SIMCTL_CALLS="$test_root/simctl-calls-failed.txt" \
  APPLE_TEST_SIM_STATE="$test_root/simulator-state" \
  APPLE_TEST_DELETE_FAIL=1 \
    apple_ios_cleanup_owned_simulators \
      "$cleanup_journal" "$test_root/simulator-results-failed" \
      "$test_root/simulator-cleanup-failed.tsv"; then
  echo "a failed simulator deletion was reported as clean" >&2
  exit 1
fi
[ -e "$test_root/simulator-results-failed/ios-27/.cleanup-required" ] || {
  echo "failed simulator deletion disarmed required cleanup" >&2
  exit 1
}
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_SIMCTL_CALLS="$test_root/simctl-calls-failed.txt" \
APPLE_TEST_SIM_STATE="$test_root/simulator-state" \
  apple_ios_cleanup_owned_simulators \
    "$cleanup_journal" "$test_root/simulator-results-failed" \
    "$test_root/simulator-cleanup-retry.tsv"
[ ! -e "$test_root/simulator-results-failed/ios-27/.cleanup-required" ] || {
  echo "a later cleanup boundary could not retry a failed simulator deletion" >&2
  exit 1
}

xctestrun_source="$test_root/source.xctestrun"
xctestrun_output="$test_root/output.xctestrun"
cat >"$xctestrun_source" <<'JSON'
{
  "__xctestrun_metadata__": {
    "FormatVersion": 2
  },
  "TestConfigurations": [
    {
      "IsEnabled": true,
      "Name": "Test Scheme Action",
      "TestTargets": [
        {
          "BlueprintName": "networkTests",
          "CommandLineArguments": [],
          "EnvironmentVariables": {
            "OS_ACTIVITY_DT_MODE": "YES"
          },
          "IsAppHostedTestBundle": true,
          "ParallelizationEnabled": true,
          "TestHostBundleIdentifier": "network.ur"
        },
        {
          "BlueprintName": "networkUITests",
          "CommandLineArguments": [],
          "EnvironmentVariables": {
            "OS_ACTIVITY_DT_MODE": "YES"
          },
          "IsUITestBundle": true,
          "ParallelizationEnabled": true,
          "TestHostBundleIdentifier": "network.ur.networkUITests.xctrunner"
        }
      ]
    }
  ]
}
JSON
plutil -convert xml1 "$xctestrun_source"
nonce=0123456789abcdef0123456789abcdef
apple_hardware_prepare_xctestrun \
  "$xctestrun_source" "$xctestrun_output" "$nonce" DEVICE-A
[ "$(plutil -extract TestConfigurations.0.TestTargets.1.EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE raw "$xctestrun_output")" = "$nonce" ]
[ "$(plutil -extract TestConfigurations.0.TestTargets.1.EnvironmentVariables.UR_HARDWARE_UI_DEVICE_ID raw "$xctestrun_output")" = DEVICE-A ]
[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.UR_HARDWARE_UI_NO_VPN raw "$xctestrun_output")" = 1 ]
[ "$(plutil -extract TestConfigurations.0.TestTargets.0.CommandLineArguments.0 raw "$xctestrun_output")" = --urnetwork-hardware-startup-no-vpn ]
apple_hardware_xctestrun_has_paired_no_vpn_contract \
  "$xctestrun_output" "$nonce" DEVICE-A

expect_xctestrun_rejected() {
  local fixture="$1"
  if apple_hardware_xctestrun_has_paired_no_vpn_contract \
    "$fixture" "$nonce" DEVICE-A; then
    echo "malformed no-VPN xctestrun was accepted: $(basename "$fixture")" >&2
    exit 1
  fi
}

cp "$xctestrun_output" "$test_root/xctestrun-no-argument.plist"
plutil -remove TestConfigurations.0.TestTargets.0.CommandLineArguments \
  "$test_root/xctestrun-no-argument.plist"
expect_xctestrun_rejected "$test_root/xctestrun-no-argument.plist"

cp "$xctestrun_output" "$test_root/xctestrun-extra-argument.plist"
plutil -replace TestConfigurations.0.TestTargets.0.CommandLineArguments \
  -json '["--urnetwork-hardware-startup-no-vpn","--tunnel-test"]' \
  "$test_root/xctestrun-extra-argument.plist"
expect_xctestrun_rejected "$test_root/xctestrun-extra-argument.plist"

cp "$xctestrun_output" "$test_root/xctestrun-no-env.plist"
plutil -remove TestConfigurations.0.TestTargets.0.EnvironmentVariables.UR_HARDWARE_UI_NO_VPN \
  "$test_root/xctestrun-no-env.plist"
expect_xctestrun_rejected "$test_root/xctestrun-no-env.plist"

cp "$xctestrun_output" "$test_root/xctestrun-wrong-nonce.plist"
plutil -replace TestConfigurations.0.TestTargets.0.EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE \
  -string fedcba9876543210fedcba9876543210 \
  "$test_root/xctestrun-wrong-nonce.plist"
expect_xctestrun_rejected "$test_root/xctestrun-wrong-nonce.plist"

cp "$xctestrun_output" "$test_root/xctestrun-malformed-env.plist"
plutil -replace TestConfigurations.0.TestTargets.0.EnvironmentVariables.UR_HARDWARE_UI_NO_VPN \
  -bool YES "$test_root/xctestrun-malformed-env.plist"
expect_xctestrun_rejected "$test_root/xctestrun-malformed-env.plist"

cp "$xctestrun_output" "$test_root/xctestrun-tunnel-env.plist"
plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.UR_ACCEPT_USER \
  -string tunnel-test "$test_root/xctestrun-tunnel-env.plist"
expect_xctestrun_rejected "$test_root/xctestrun-tunnel-env.plist"

cp "$xctestrun_output" "$test_root/xctestrun-ui-argument.plist"
plutil -replace TestConfigurations.0.TestTargets.1.CommandLineArguments \
  -json '["--tunnel-test"]' "$test_root/xctestrun-ui-argument.plist"
expect_xctestrun_rejected "$test_root/xctestrun-ui-argument.plist"

expect_xctestrun_source_rejected() {
  local fixture="$1"
  local rejected_output="${2:-$test_root/rejected-output.xctestrun}"
  rm -f "$rejected_output"
  if apple_hardware_prepare_xctestrun \
    "$fixture" "$rejected_output" "$nonce" DEVICE-A 2>/dev/null; then
    echo "malformed source xctestrun was accepted: $(basename "$fixture")" >&2
    exit 1
  fi
  [ ! -e "$rejected_output" ] || {
    echo "rejected source left a runnable xctestrun: $(basename "$fixture")" >&2
    exit 1
  }
}

mkdir "$test_root/relocated"
expect_xctestrun_source_rejected \
  "$xctestrun_source" "$test_root/relocated/output.xctestrun"

cp "$xctestrun_source" "$test_root/source-format-v1.plist"
plutil -replace __xctestrun_metadata__.FormatVersion -integer 1 \
  "$test_root/source-format-v1.plist"
expect_xctestrun_source_rejected "$test_root/source-format-v1.plist"

cp "$xctestrun_source" "$test_root/source-disabled.plist"
plutil -replace TestConfigurations.0.IsEnabled -bool NO \
  "$test_root/source-disabled.plist"
expect_xctestrun_source_rejected "$test_root/source-disabled.plist"

plutil -convert json -o - "$xctestrun_source" | \
  jq '.TestConfigurations[0].TestTargets += [.TestConfigurations[0].TestTargets[0]]' \
  >"$test_root/source-duplicate-target.json"
expect_xctestrun_source_rejected "$test_root/source-duplicate-target.json"

plutil -convert json -o - "$xctestrun_source" | \
  jq 'del(.TestConfigurations[0].TestTargets[1])' \
  >"$test_root/source-missing-target.json"
expect_xctestrun_source_rejected "$test_root/source-missing-target.json"

cp "$xctestrun_source" "$test_root/source-tunnel-env.plist"
plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.URNETWORK_PHYSICAL_TEST_ACTION \
  -string tunnel "$test_root/source-tunnel-env.plist"
expect_xctestrun_source_rejected "$test_root/source-tunnel-env.plist"

cp "$xctestrun_source" "$test_root/source-preselected.plist"
plutil -insert TestConfigurations.0.TestTargets.0.OnlyTestIdentifiers \
  -json '["networkTests/OneTest"]' "$test_root/source-preselected.plist"
expect_xctestrun_source_rejected "$test_root/source-preselected.plist"

printf 'Test run with 42 tests in 10 suites passed after 1.0 seconds.\n' >"$test_root/unit-pass.log"
apple_hardware_verify_unit_log "$test_root/unit-pass.log"
printf 'Test skipped\nTest run with 42 tests in 10 suites passed after 1.0 seconds.\n' >"$test_root/unit-skipped.log"
if apple_hardware_verify_unit_log "$test_root/unit-skipped.log"; then
  echo "a skipped unit corpus was accepted" >&2
  exit 1
fi

printf 'UR_HARDWARE_STARTUP_PASS device=DEVICE-A\n' >"$test_root/pass.log"
apple_hardware_verify_test_log "$test_root/pass.log" DEVICE-A
printf 'UR_HARDWARE_STARTUP_PASS device=DEVICE-A\nUR_HARDWARE_STARTUP_PASS device=DEVICE-A\n' >"$test_root/duplicate.log"
if apple_hardware_verify_test_log "$test_root/duplicate.log" DEVICE-A; then
  echo "duplicate UI completion markers were accepted" >&2
  exit 1
fi
printf 'Test skipped\nUR_HARDWARE_STARTUP_PASS device=DEVICE-A\n' >"$test_root/skipped.log"
if apple_hardware_verify_test_log "$test_root/skipped.log" DEVICE-A; then
  echo "a skipped UI test was accepted" >&2
  exit 1
fi

apple_hardware_source_contract "$here"
grep -Fq 'run_bounded 3600 make build_apple' \
  "$here/test-hardware-startup.sh" || {
    echo "iOS simulator runner does not rebuild the local Apple SDK" >&2
    exit 1
  }
grep -Fq $'apple\\thardware-startup-no-vpn\\tPASS' \
  "$here/test-hardware-startup.sh" || {
    echo "iOS simulator runner does not publish its aggregate pass result" >&2
    exit 1
  }

mkdir -p "$test_root/source-audit"
touch "$test_root/source-audit/VPNProfileSystem.swift"
cat >"$test_root/source-audit/EscapedProfileAccess.swift" <<'SWIFT'
func escapedProfileAccess(profile: NETunnelProviderManager) {
    profile.saveToPreferences { _ in }
}
SWIFT
if [ -z "$(apple_hardware_find_unguarded_profile_calls \
  "$test_root/source-audit" \
  "$test_root/source-audit/VPNProfileSystem.swift")" ]; then
  echo "an alternate profile variable escaped the forbidden-call audit" >&2
  exit 1
fi

inventory_line="$(grep -n 'capture_runtime_inventory "$runtime_inventory"' "$here/test-hardware-startup.sh" | cut -d: -f1)"
build_line="$(grep -n 'xcodebuild build-for-testing' "$here/test-hardware-startup.sh" | sed -n '1s/:.*//p')"
[ "$inventory_line" -lt "$build_line" ] || {
  echo "the app build can begin before immutable simulator inventory capture" >&2
  exit 1
}
[ "$(grep -c 'xcodebuild build-for-testing' \
  "$here/test-hardware-startup.sh")" -eq 1 ] || {
  echo "the iOS simulator runner does not build exactly one simulator bundle" >&2
  exit 1
}
[ "$(grep -c -- '^[[:space:]]*-jobs 1' \
  "$here/test-hardware-startup.sh")" -eq 3 ] || {
  echo "an iOS simulator xcodebuild invocation exceeds the one-worker budget" >&2
  exit 1
}
[ "$(grep -c -- '-parallel-testing-enabled NO' \
  "$here/test-hardware-startup.sh")" -eq 2 ] || {
  echo "an iOS simulator test invocation permits parallel test workers" >&2
  exit 1
}
if grep -Eq -- '--device=|--udid=|--only-testing=' "$here/test-hardware-startup.sh"; then
  echo "the hardware runner exposes a fleet/test selector" >&2
  exit 1
fi
grep -Fq -- '-downloadPlatform iOS' \
  "$here/test-hardware-startup-lib.sh" || {
  echo "the iOS simulator runner cannot provision missing simulator runtimes" >&2
  exit 1
}
for lifecycle_command in create boot bootstatus; do
  grep -Eq "xcrun simctl ${lifecycle_command}([[:space:]]|\")" \
    "$here/test-hardware-startup.sh" || {
    echo "the iOS simulator runner is missing simctl $lifecycle_command" >&2
    exit 1
  }
done
for lifecycle_command in shutdown delete; do
  grep -Eq "xcrun simctl ${lifecycle_command}([[:space:]]|\")" \
    "$here/test-hardware-startup-lib.sh" || {
    echo "simulator cleanup is missing simctl $lifecycle_command" >&2
    exit 1
  }
done
[ "$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;' \
  "$here/app/app.xcodeproj/project.pbxproj")" -eq 8 ] || {
  echo "an app, extension, or test target lost deployment support for iOS 16" >&2
  exit 1
}
if grep -Eq 'IPHONEOS_DEPLOYMENT_TARGET = (16\.6|18\.1);' \
  "$here/app/app.xcodeproj/project.pbxproj"; then
  echo "a raised deployment target excludes supported iOS 16 devices" >&2
  exit 1
fi

bash "$here/test-hardware-startup-runner.test.sh"
echo "apple simulator startup runner tests passed"
