#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/test-hardware-startup-lib.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-hardware-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

inventory="$test_root/inventory.json"
plan="$test_root/plan.json"
skips="$test_root/skips.tsv"
cat >"$inventory" <<'JSON'
[
  {
    "simulator": false,
    "platform": "com.apple.platform.iphoneos",
    "identifier": "STALE-WIFI",
    "name": "Stale wireless phone",
    "modelName": "iPhone 14",
    "operatingSystemVersion": "18.6",
    "architecture": "arm64e",
    "interface": "network",
    "available": false,
    "ignored": false
  },
  {
    "simulator": true,
    "platform": "com.apple.platform.iphonesimulator",
    "identifier": "SIMULATOR",
    "name": "Ignored simulator",
    "operatingSystemVersion": "18.6",
    "architecture": "arm64",
    "interface": "usb",
    "available": true,
    "ignored": false
  },
  {
    "simulator": false,
    "platform": "com.apple.platform.iphoneos",
    "identifier": "DEVICE-A",
    "name": "First phone",
    "modelName": "iPhone 15 Pro",
    "operatingSystemVersion": "18.5",
    "architecture": "arm64",
    "interface": "usb",
    "available": true,
    "ignored": false
  },
  {
    "simulator": false,
    "platform": "com.apple.platform.iphoneos",
    "identifier": "DEVICE-C",
    "name": "Third phone",
    "modelName": "iPhone 16 Pro Max",
    "operatingSystemVersion": "18.6",
    "architecture": "arm64e",
    "interface": "usb",
    "available": true,
    "ignored": false
  },
  {
    "simulator": false,
    "platform": "com.apple.platform.iphoneos",
    "identifier": "DEVICE-OLD",
    "name": "Unsupported phone",
    "modelName": "iPhone 11 Pro",
    "operatingSystemVersion": "16.7.11 (20H360)",
    "architecture": "arm64",
    "interface": "usb",
    "available": true,
    "ignored": false
  }
]
JSON
apple_hardware_write_inventory_plan "$inventory" "$plan" "$skips" 18 1
[ "$(apple_hardware_plan_count "$plan")" -eq 2 ]
[ "$(apple_hardware_plan_ids "$plan" | paste -sd, -)" = "DEVICE-A,DEVICE-C" ] || {
  echo "attached physical devices were not planned once in stable order" >&2
  exit 1
}
[ "$(cat "$skips")" = $'DEVICE-OLD\tUnsupported phone\t16.7.11 (20H360)\trequires-ios-18.1' ] || {
  echo "unsupported physical device did not receive its exact capability skip" >&2
  exit 1
}
real_device_matrix="$test_root/real-device-matrix.md"
apple_hardware_write_real_device_matrix "$plan" "$real_device_matrix"
grep -Fq '| Acceptance test | iPhone 15 Pro / iOS 18.5 | iPhone 16 Pro Max / iOS 18.6 |' \
  "$real_device_matrix" || {
  echo "the real-device report did not use model/OS columns" >&2
  exit 1
}
[ "$(grep -cF '| RUN | RUN |' "$real_device_matrix")" -eq 2 ] || {
  echo "the real-device report did not mark both test/device cells" >&2
  exit 1
}
jq '.[0].modelName = "Phone | special"' "$plan" \
  >"$test_root/escaped-matrix-plan.json"
apple_hardware_write_real_device_matrix \
  "$test_root/escaped-matrix-plan.json" "$test_root/escaped-matrix.md"
grep -Fq 'Phone \| special / iOS 18.5' "$test_root/escaped-matrix.md" || {
  echo "a device model could corrupt the Markdown matrix" >&2
  exit 1
}

printf 'DEVICE-A\nDEVICE-OLD\n' >"$test_root/usb-identifiers.txt"
apple_hardware_usb_inventory_is_represented \
  "$inventory" "$test_root/usb-identifiers.txt"

cat >"$test_root/ioreg.txt" <<'IOREG'
  | "USB Serial Number" = "00008140001679DE0893C01C"
  | "USB Serial Number" = "00008140001679DE0893C01C"
  | "USB Serial Number" = "ac5ee3d940bb92b36f44c66bb2d5bda8eb70786f"
IOREG
apple_hardware_write_usb_identifiers \
  "$test_root/ioreg.txt" "$test_root/normalized-usb-identifiers.txt"
[ "$(cat "$test_root/normalized-usb-identifiers.txt")" = \
  $'00008140-001679DE0893C01C\nac5ee3d940bb92b36f44c66bb2d5bda8eb70786f' ] || {
  echo "physical USB identifiers were not normalized and deduplicated" >&2
  exit 1
}
printf '%s\n' '  | "USB Serial Number" = "not-a-device-id"' \
  >"$test_root/ioreg-malformed.txt"
if apple_hardware_write_usb_identifiers \
    "$test_root/ioreg-malformed.txt" \
    "$test_root/malformed-usb-identifiers.txt"; then
  echo "a malformed physical USB identifier was accepted" >&2
  exit 1
fi
[ ! -e "$test_root/malformed-usb-identifiers.txt" ] || {
  echo "a malformed physical USB inventory left an authoritative output" >&2
  exit 1
}

printf 'CONNECTED-MISSING\n' >"$test_root/missing-usb-identifier.txt"
if apple_hardware_usb_inventory_is_represented \
    "$inventory" "$test_root/missing-usb-identifier.txt"; then
  echo "an unavailable physical USB attachment was silently omitted" >&2
  exit 1
fi

inventory_hash="$(apple_hardware_sha256 "$inventory")"
apple_hardware_inventory_unchanged "$inventory" "$inventory_hash"
printf ' ' >>"$inventory"
if apple_hardware_inventory_unchanged "$inventory" "$inventory_hash"; then
  echo "mutated inventory passed its immutable hash check" >&2
  exit 1
fi
sed -i '' -e '$ s/ $//' "$inventory"

jq 'map(if .identifier == "DEVICE-A" then .available = false else . end)' \
  "$inventory" >"$test_root/offline.json"
apple_hardware_write_inventory_plan \
  "$test_root/offline.json" "$test_root/offline-plan.json" \
  "$test_root/offline-skips.tsv" 18 1
[ "$(apple_hardware_plan_ids "$test_root/offline-plan.json" | paste -sd, -)" = \
  DEVICE-C ] || {
  echo "stale unavailable Xcode records were not excluded from the plan" >&2
  exit 1
}
if apple_hardware_usb_inventory_is_represented \
    "$test_root/offline.json" "$test_root/usb-identifiers.txt"; then
  echo "a physically connected but unavailable target passed USB validation" >&2
  exit 1
fi
jq 'map(if .identifier == "DEVICE-A" then .simulator = null else . end)' \
  "$inventory" >"$test_root/malformed-attached.json"
if apple_hardware_write_inventory_plan \
  "$test_root/malformed-attached.json" \
  "$test_root/malformed-attached-plan.json" \
  "$test_root/malformed-attached-skips.tsv" 18 1 2>/dev/null; then
  echo "an attached device with malformed physical metadata was omitted" >&2
  exit 1
fi
jq 'map(if .identifier == "DEVICE-A" then del(.modelName) else . end)' \
  "$inventory" >"$test_root/missing-model.json"
if apple_hardware_write_inventory_plan \
  "$test_root/missing-model.json" \
  "$test_root/missing-model-plan.json" \
  "$test_root/missing-model-skips.tsv" 18 1 2>/dev/null; then
  echo "an attached device without a reportable model entered the plan" >&2
  exit 1
fi
jq 'map(if .identifier == "DEVICE-A" then .ignored = true else . end)' \
  "$inventory" >"$test_root/unauthorized.json"
if apple_hardware_write_inventory_plan \
  "$test_root/unauthorized.json" \
  "$test_root/unauthorized-plan.json" \
  "$test_root/unauthorized-skips.tsv" 18 1 2>/dev/null; then
  echo "an ignored attached device entered the plan" >&2
  exit 1
fi
jq '. + [(.[] | select(.identifier == "DEVICE-A"))]' \
  "$inventory" >"$test_root/duplicate.json"
if apple_hardware_write_inventory_plan \
  "$test_root/duplicate.json" "$test_root/duplicate-plan.json" \
  "$test_root/duplicate-skips.tsv" 18 1 2>/dev/null; then
  echo "duplicate physical device entered the plan" >&2
  exit 1
fi
jq '[.[] | select(.simulator == true)]' "$inventory" >"$test_root/empty.json"
apple_hardware_write_inventory_plan \
  "$test_root/empty.json" "$test_root/empty-plan.json" \
  "$test_root/empty-skips.tsv" 18 1
[ "$(apple_hardware_plan_count "$test_root/empty-plan.json")" -eq 0 ] || {
  echo "an empty physical inventory did not produce an empty plan" >&2
  exit 1
}
apple_hardware_write_real_device_matrix \
  "$test_root/empty-plan.json" "$test_root/empty-real-device-matrix.md"
grep -Fq 'no real-device cells run' \
  "$test_root/empty-real-device-matrix.md" || {
  echo "an empty real-device plan did not produce an explicit empty report" >&2
  exit 1
}

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
  $'ios-16\t16\t16.4\nios-17\t17\t17.2\nios-18\t18\t18.5\nios-2026\t26\t26.5' ] || {
  echo "the required iOS simulator release matrix changed" >&2
  exit 1
}
apple_ios_write_simulator_runtime_plan "$runtime_inventory" "$runtime_plan"
[ "$(apple_hardware_plan_count "$runtime_plan")" -eq 4 ]
[ "$(apple_hardware_plan_ids "$runtime_plan" | paste -sd, -)" = \
  "ios-16,ios-17,ios-18,ios-2026" ] || {
  echo "the simulator runtime plan omitted or reordered a required lane" >&2
  exit 1
}
[ "$(jq -r 'map(.runtimeVersion) | join(",")' "$runtime_plan")" = \
  "16.4,17.5,18.5,26.5" ] || {
  echo "the simulator runtime plan did not select the newest installed patch" >&2
  exit 1
}
[ "$(jq -r '.[0].deviceTypeIdentifier' "$runtime_plan")" = \
  com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro ] || {
  echo "the simulator plan did not preserve a compatible iPhone type" >&2
  exit 1
}
apple_ios_runtime_plan_supports_deployment_target "$runtime_plan" 16 0
if apple_ios_runtime_plan_supports_deployment_target \
  "$runtime_plan" 16 6; then
  echo "an iOS 16.4 runtime accepted an iOS 16.6 deployment target" >&2
  exit 1
fi
[ -z "$(apple_ios_missing_simulator_downloads "$runtime_inventory")" ] || {
  echo "an already complete runtime inventory requested a download" >&2
  exit 1
}

jq '.runtimes |= map(select(.version != "17.5"))' \
  "$runtime_inventory" >"$test_root/runtime-missing-17.json"
[ "$(apple_ios_missing_simulator_downloads \
  "$test_root/runtime-missing-17.json")" = $'ios-17\t17\t17.2' ] || {
  echo "the missing iOS 17 runtime did not select its pinned download" >&2
  exit 1
}
if apple_ios_write_simulator_runtime_plan \
  "$test_root/runtime-missing-17.json" \
  "$test_root/runtime-missing-plan.json" 2>/dev/null; then
  echo "an incomplete simulator runtime inventory produced a runnable plan" >&2
  exit 1
fi
[ ! -e "$test_root/runtime-missing-plan.json" ] || {
  echo "a rejected simulator runtime inventory left an authoritative plan" >&2
  exit 1
}

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
apple_ios_append_owned_simulator \
  "$owned_journal" ios-16 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-16-20260905-120000Z
apple_ios_append_owned_simulator \
  "$owned_journal" ios-17 11111111-2222-3333-4444-555555555555 \
  urnetwork-acceptance-ios-17-20260905-120000Z
apple_ios_validate_owned_simulator_journal "$owned_journal"
apple_ios_owned_simulator_journal_has_identity \
  "$owned_journal" ios-16 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-16-20260905-120000Z
if apple_ios_owned_simulator_journal_has_identity \
  "$owned_journal" ios-16 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-16-20260905-120001Z; then
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
  {"udid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"urnetwork-acceptance-ios-16-20260905-120000Z","state":"Booted","isAvailable":true},
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
  "$cleanup_journal" ios-16 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  urnetwork-acceptance-ios-16-20260905-120000Z
mkdir -p "$test_root/simulator-results/ios-16"
touch "$test_root/simulator-results/ios-16/.cleanup-required"
printf 'present\n' >"$test_root/simulator-state"
: >"$test_root/simctl-calls.txt"
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_SIMCTL_CALLS="$test_root/simctl-calls.txt" \
APPLE_TEST_SIM_STATE="$test_root/simulator-state" \
  apple_ios_cleanup_owned_simulators \
    "$cleanup_journal" "$test_root/simulator-results" \
    "$test_root/simulator-cleanup.tsv"
[ ! -e "$test_root/simulator-results/ios-16/.cleanup-required" ] || {
  echo "successful simulator deletion left cleanup armed" >&2
  exit 1
}
[ "$(cat "$test_root/simulator-cleanup.tsv")" = \
  $'ios-16\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tPASS\tshutdown-and-deleted' ] || {
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

mkdir -p "$test_root/simulator-results-failed/ios-16"
touch "$test_root/simulator-results-failed/ios-16/.cleanup-required"
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
[ -e "$test_root/simulator-results-failed/ios-16/.cleanup-required" ] || {
  echo "failed simulator deletion disarmed required cleanup" >&2
  exit 1
}
PATH="$test_root/fake-bin:$PATH" \
APPLE_TEST_SIMCTL_CALLS="$test_root/simctl-calls-failed.txt" \
APPLE_TEST_SIM_STATE="$test_root/simulator-state" \
  apple_ios_cleanup_owned_simulators \
    "$cleanup_journal" "$test_root/simulator-results-failed" \
    "$test_root/simulator-cleanup-retry.tsv"
[ ! -e "$test_root/simulator-results-failed/ios-16/.cleanup-required" ] || {
  echo "a later cleanup boundary could not retry a failed simulator deletion" >&2
  exit 1
}

cat >"$test_root/details-usable.json" <<'JSON'
{
  "info": {
    "commandType": "devicectl.device.info.details",
    "outcome": "success"
  },
  "result": {
    "identifier": "CORE-DEVICE-A",
    "hardwareProperties": {
      "reality": "physical",
      "udid": "DEVICE-A"
    },
    "connectionProperties": {
      "pairingState": "paired"
    },
    "deviceProperties": {
      "bootState": "booted",
      "developerModeStatus": "enabled",
      "ddiServicesAvailable": true
    }
  }
}
JSON
cat >"$test_root/unlocked.json" <<'JSON'
{
  "info": {
    "commandType": "devicectl.device.info.lockState",
    "outcome": "success"
  },
  "result": {
    "deviceIdentifier": "CORE-DEVICE-A",
    "passcodeRequired": false,
    "unlockedSinceBoot": true
  }
}
JSON
apple_hardware_device_details_are_usable \
  "$test_root/details-usable.json" DEVICE-A
[ "$(apple_hardware_device_details_identifier \
  "$test_root/details-usable.json")" = CORE-DEVICE-A ]
apple_hardware_lock_state_is_unlocked \
  "$test_root/unlocked.json" CORE-DEVICE-A

while IFS=$'\t' read -r name filter; do
  jq "$filter" "$test_root/details-usable.json" \
    >"$test_root/details-$name.json"
  if apple_hardware_device_details_are_usable \
    "$test_root/details-$name.json" DEVICE-A; then
    echo "unusable CoreDevice details fixture was accepted: $name" >&2
    exit 1
  fi
done <<'CASES'
virtual	.result.hardwareProperties.reality = "virtual"
wrong-udid	.result.hardwareProperties.udid = "DEVICE-B"
unpaired	.result.connectionProperties.pairingState = "unpaired"
not-booted	.result.deviceProperties.bootState = "shutdown"
developer-mode-disabled	.result.deviceProperties.developerModeStatus = "disabled"
ddi-unavailable	.result.deviceProperties.ddiServicesAvailable = false
malformed-ddi	.result.deviceProperties.ddiServicesAvailable = "true"
missing-pairing	del(.result.connectionProperties.pairingState)
failed-outcome	.info.outcome = "failure"
malformed-result	.result = []
CASES

while IFS=$'\t' read -r name filter; do
  jq "$filter" "$test_root/unlocked.json" >"$test_root/lock-$name.json"
  if apple_hardware_lock_state_is_unlocked \
    "$test_root/lock-$name.json" CORE-DEVICE-A; then
    echo "unusable CoreDevice lock fixture was accepted: $name" >&2
    exit 1
  fi
done <<'CASES'
passcode-required	.result.passcodeRequired = true
never-unlocked	.result.unlockedSinceBoot = false
wrong-identifier	.result.deviceIdentifier = "CORE-DEVICE-B"
missing-unlock-state	del(.result.unlockedSinceBoot)
malformed-passcode	.result.passcodeRequired = "false"
failed-outcome	.info.outcome = "failure"
CASES

cat >"$test_root/apps-clean.json" <<'JSON'
{"info": {"outcome": "success"}, "result": {"apps": []}}
JSON
cat >"$test_root/apps-dirty.json" <<'JSON'
{"info": {"outcome": "success"}, "result": {"apps": [{"bundleIdentifier": "network.ur"}]}}
JSON
cat >"$test_root/apps-unknown.json" <<'JSON'
{"info": {"outcome": "success"}, "result": {}}
JSON
cat >"$test_root/apps-failed.json" <<'JSON'
{"info": {"outcome": "failure"}, "result": {"apps": []}}
JSON
apple_hardware_app_query_is_clean "$test_root/apps-clean.json" network.ur
apple_hardware_app_query_has_bundle "$test_root/apps-dirty.json" network.ur
if apple_hardware_app_query_is_clean "$test_root/apps-dirty.json" network.ur; then
  echo "pre-existing app state was accepted" >&2
  exit 1
fi
if apple_hardware_app_query_is_clean "$test_root/apps-unknown.json" network.ur; then
  echo "unknown app inventory was accepted" >&2
  exit 1
fi
if apple_hardware_app_query_is_clean "$test_root/apps-failed.json" network.ur; then
  echo "a failed app inventory was accepted as clean" >&2
  exit 1
fi

results_root="$test_root/results"
mkdir -p "$results_root/DEVICE-A" "$results_root/DEVICE-C"
apple_hardware_write_result_once \
  "$results_root/DEVICE-A/status.tsv" DEVICE-A PASS startup-no-vpn
apple_hardware_write_result_once \
  "$results_root/DEVICE-C/status.tsv" DEVICE-C FAIL test-or-cleanup
apple_hardware_results_match_plan "$plan" "$results_root"
if apple_hardware_write_result_once \
  "$results_root/DEVICE-A/status.tsv" DEVICE-A PASS duplicate 2>/dev/null; then
  echo "a device result was overwritten" >&2
  exit 1
fi
rm "$results_root/DEVICE-C/status.tsv"
if apple_hardware_results_match_plan "$plan" "$results_root"; then
  echo "an incomplete result set matched the device plan" >&2
  exit 1
fi

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
    echo "physical iOS runner does not rebuild the local Apple SDK" >&2
    exit 1
  }
grep -Fq $'apple\\thardware-startup-no-vpn\\tPASS' \
  "$here/test-hardware-startup.sh" || {
    echo "physical iOS runner does not publish its aggregate pass result" >&2
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

inventory_line="$(grep -n 'xcrun xcdevice list' "$here/test-hardware-startup.sh" | cut -d: -f1)"
build_line="$(grep -n 'xcodebuild build-for-testing' "$here/test-hardware-startup.sh" | sed -n '1s/:.*//p')"
[ "$inventory_line" -lt "$build_line" ] || {
  echo "the app build can begin before immutable fleet capture" >&2
  exit 1
}
[ "$(grep -c 'xcodebuild build-for-testing' \
  "$here/test-hardware-startup.sh")" -eq 2 ] || {
  echo "the iOS device runner does not build both physical and simulator bundles" >&2
  exit 1
}
[ "$(grep -c 'xcrun xcdevice list' "$here/test-hardware-startup.sh")" -eq 1 ] || {
  echo "the hardware runner can recapture or drift its device inventory" >&2
  exit 1
}
[ "$(grep -c -- '^[[:space:]]*-jobs 1' \
  "$here/test-hardware-startup.sh")" -eq 6 ] || {
  echo "an iOS-device xcodebuild invocation exceeds the one-worker budget" >&2
  exit 1
}
[ "$(grep -c -- '-parallel-testing-enabled NO' \
  "$here/test-hardware-startup.sh")" -eq 4 ] || {
  echo "an iOS-device test invocation permits parallel test workers" >&2
  exit 1
}
if grep -Eq -- '--device=|--udid=|--only-testing=' "$here/test-hardware-startup.sh"; then
  echo "the hardware runner exposes a fleet/test selector" >&2
  exit 1
fi
grep -Fq -- '-downloadPlatform iOS' \
  "$here/test-hardware-startup-lib.sh" || {
  echo "the iOS device runner cannot provision missing simulator runtimes" >&2
  exit 1
}
for lifecycle_command in create boot bootstatus; do
  grep -Eq "xcrun simctl ${lifecycle_command}([[:space:]]|\")" \
    "$here/test-hardware-startup.sh" || {
    echo "the iOS device runner is missing simctl $lifecycle_command" >&2
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
grep -Fq 'real-device-matrix.md' "$here/test-hardware-startup.sh" || {
  echo "the iOS device runner does not publish its real-device matrix" >&2
  exit 1
}
[ "$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;' \
  "$here/app/app.xcodeproj/project.pbxproj")" -eq 8 ] || {
  echo "an app, extension, or test target cannot run on the iOS 16.4 lane" >&2
  exit 1
}
if grep -Eq 'IPHONEOS_DEPLOYMENT_TARGET = (16\.6|18\.1);' \
  "$here/app/app.xcodeproj/project.pbxproj"; then
  echo "a stale deployment target excludes a required simulator lane" >&2
  exit 1
fi

echo "apple hardware startup runner tests passed"
