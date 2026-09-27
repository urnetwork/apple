#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the real entry point with isolated command fixtures. No Apple
# service, physical device, simulator, build, or network gate is contacted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-simulator-runner.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "simulator startup runner regression: $*" >&2
  exit 1
}

mkdir "$test_root/bin"
cat >"$test_root/bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --foreground ] || shift
shift
exec "$@"
SH
cat >"$test_root/bin/ioreg" <<'SH'
#!/usr/bin/env bash
printf 'physical ioreg %s\n' "$*" >>"$APPLE_RUNNER_CALLS"
exit 97
SH
cat >"$test_root/bin/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = build_apple ]
printf 'sdk build\n' >>"$APPLE_RUNNER_CALLS"
mkdir -p "$PWD/apple/URnetworkSdk.xcframework" \
  "$PWD/apple/URnetworkExtensionSdk.xcframework"
SH
cat >"$test_root/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >>"$APPLE_RUNNER_CALLS"
if [ "${1:-}" != simctl ]; then
  printf 'physical xcrun %s\n' "$*" >>"$APPLE_RUNNER_CALLS"
  exit 97
fi
shift
case "${1:-}" in
  list)
    case "${2:-} ${3:-}" in
      'runtimes --json')
        jq -n --arg mode "$APPLE_RUNNER_MODE" '{runtimes: [
          "17.2", "18.5", "26.5", "27.0"
          | select($mode != "missing-runtime" or . != "17.2")
          | . as $version | {
            platform: "iOS", version: $version, buildversion: "fixture",
            identifier: ("com.apple.CoreSimulator.SimRuntime.iOS-" + ($version | gsub("\\."; "-"))),
            isAvailable: true, supportedDeviceTypes: [{productFamily: "iPhone",
              name: "iPhone Fixture", identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Fixture"}]
          }
        ]}'
        ;;
      'devices --json')
        jq -Rn --arg mode "$APPLE_RUNNER_MODE" '{devices: {fixture: [
          inputs | split("\t") | {
            udid: .[0], name: (if $mode == "ownership-mismatch" and .[1] != "user-simulator"
              then "changed-owner" else .[1] end), state: "Booted", isAvailable: true
          }
        ]}}' <"$APPLE_RUNNER_DEVICES"
        ;;
      *) exit 98 ;;
    esac
    ;;
  create)
    release="${2#urnetwork-acceptance-ios-}"
    release="${release%%-*}"
    udid="$(printf '%08d-1111-2222-3333-444444444444' "$release")"
    printf '%s\t%s\n' "$udid" "$2" >>"$APPLE_RUNNER_DEVICES"
    printf '%s\n' "$udid"
    ;;
  boot|spawn|shutdown) ;;
  bootstatus)
    if [ "$APPLE_RUNNER_MODE" = terminate ]; then
      kill -TERM "$PPID"
    fi
    ;;
  delete)
    [ "$2" != 99999999-1111-2222-3333-444444444444 ] || exit 99
    [ "$APPLE_RUNNER_MODE" != cleanup-failure ] || exit 8
    awk -F '\t' -v udid="$2" '$1 != udid' "$APPLE_RUNNER_DEVICES" \
      >"$APPLE_RUNNER_DEVICES.tmp"
    mv "$APPLE_RUNNER_DEVICES.tmp" "$APPLE_RUNNER_DEVICES"
    ;;
  *) exit 98 ;;
esac
SH
cat >"$test_root/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >>"$APPLE_RUNNER_CALLS"
mode="" destination="" sdk="" derived="" build_id="" nonce="" xctestrun="" target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -showBuildSettings|build-for-testing|test-without-building|-downloadPlatform) mode="$1" ;;
    -sdk) shift; sdk="$1" ;;
    -destination) shift; destination="$1" ;;
    -derivedDataPath) shift; derived="$1" ;;
    -xctestrun) shift; xctestrun="$1" ;;
    URNETWORK_ACCEPTANCE_BUILD_ID=*) build_id="${1#*=}" ;;
    URNETWORK_HARDWARE_UI_TEST_NONCE=*) nonce="${1#*=}" ;;
    -only-testing:*) target="${1#*:}" ;;
  esac
  shift
done
if [ "$sdk" = iphoneos ] || [[ "$destination" == 'platform=iOS,'* ]] || \
    [ "$destination" = generic/platform=iOS ]; then
  printf 'physical xcodebuild\n' >>"$APPLE_RUNNER_CALLS"
  exit 97
fi
case "$mode" in
  -showBuildSettings)
    [ "$sdk" = iphonesimulator ]
    printf '    IPHONEOS_DEPLOYMENT_TARGET = 16.0\n'
    ;;
  -downloadPlatform) exit 7 ;;
  build-for-testing)
    [ "$destination" = 'generic/platform=iOS Simulator' ]
    products="$derived/Build/Products"
    mkdir -p "$products/Debug-iphonesimulator/URnetwork.app"
    jq -n --arg build "$build_id" --arg nonce "$nonce" \
      '{URAcceptanceBuildID: $build, URHardwareUITestNonce: $nonce}' \
      >"$products/Debug-iphonesimulator/URnetwork.app/Info.plist"
    plutil -convert xml1 "$products/Debug-iphonesimulator/URnetwork.app/Info.plist"
    jq -n '{__xctestrun_metadata__: {FormatVersion: 2}, TestConfigurations: [{
      IsEnabled: true, TestTargets: [
        {BlueprintName: "networkTests", CommandLineArguments: [], EnvironmentVariables: {},
          IsAppHostedTestBundle: true, TestHostBundleIdentifier: "network.ur"},
        {BlueprintName: "networkUITests", CommandLineArguments: [], EnvironmentVariables: {},
          IsUITestBundle: true, TestHostBundleIdentifier: "network.ur.networkUITests.xctrunner"}
      ]
    }]}' >"$products/fixture.xctestrun"
    plutil -convert xml1 "$products/fixture.xctestrun"
    ;;
  test-without-building)
    [[ "$destination" == 'platform=iOS Simulator,id='* ]]
    udid="${destination##*=}"
    source "$URNETWORK_ROOT/apple/test-hardware-startup-lib.sh"
    nonce="$(plutil -extract TestConfigurations.0.TestTargets.1.EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE raw "$xctestrun")"
    apple_hardware_xctestrun_has_paired_no_vpn_contract "$xctestrun" "$nonce" "$udid"
    case "$target" in
      networkTests)
        [ "$APPLE_RUNNER_MODE" != unit-failure ] || exit 6
        printf 'Test run with 42 tests in 10 suites passed after 1.0 seconds.\n'
        ;;
      networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess)
        [ "$APPLE_RUNNER_MODE" != ui-failure ] || exit 6
        printf 'UR_HARDWARE_STARTUP_PASS device=%s\n' "$udid"
        ;;
      *) exit 98 ;;
    esac
    ;;
  *) exit 98 ;;
esac
SH
chmod 700 "$test_root/bin/"*

run_fixture() {
  local mode="$1" expected_status="$2" fixture status artifacts
  fixture="$test_root/$mode"
  mkdir -p "$fixture/apple" "$fixture/tests" "$fixture/sdk/build" "$fixture/tools/go-bin"
  cp "$here/test-hardware-startup.sh" "$here/test-hardware-startup-lib.sh" "$fixture/apple/"
  printf '#!/usr/bin/env bash\n[ "$*" = "--verify-held main-acceptance" ]\n' \
    >"$fixture/tests/network-intensive-suite-lock.sh"
  chmod 700 "$fixture/tests/network-intensive-suite-lock.sh"
  for tool in gomobile gobind checksec; do
    cp "$test_root/bin/ioreg" "$fixture/tools/go-bin/$tool"
  done
  printf '99999999-1111-2222-3333-444444444444\tuser-simulator\n' >"$fixture/devices.tsv"
  : >"$fixture/calls.log"
  status=0
  env PATH="$test_root/bin:$PATH" URNETWORK_ROOT="$fixture" \
    URNETWORK_NETWORK_TEST_LOCK_HELD=1 UR_ACCEPT_APPLE_TOOLS="$fixture/tools" \
    WARP_VERSION=fixture UR_ACCEPT_REPEAT=2 UR_ACCEPT_RESULT_FILE="$fixture/matrix.tsv" \
    APPLE_RUNNER_MODE="$mode" APPLE_RUNNER_CALLS="$fixture/calls.log" \
    APPLE_RUNNER_DEVICES="$fixture/devices.tsv" \
    bash "$fixture/apple/test-hardware-startup.sh" >"$fixture/run.log" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    tail -n 12 "$fixture/run.log" >&2
    fail "$mode exited $status; expected $expected_status"
  fi
  if grep -q '^physical ' "$fixture/calls.log"; then
    fail "$mode contacted a physical iPhone command"
  fi
  [ "$(wc -l <"$fixture/matrix.tsv" | tr -d ' ')" -eq 1 ] || \
    fail "$mode did not write exactly one aggregate result"
  artifacts="$(find "$fixture/apple/tests/__hardware_startup__" -mindepth 1 -maxdepth 1 -type d)"
  [ -d "$artifacts" ] || fail "$mode has no artifact directory"
  [ ! -e "$artifacts/device-plan.json" ] && \
    [ ! -e "$artifacts/real-device-matrix.md" ] || fail "$mode claimed physical proof"
  if [ "$expected_status" -eq 0 ]; then
    grep -q $'^apple\thardware-startup-no-vpn\tPASS\t4 required simulator lane(s) passed$' \
      "$fixture/matrix.tsv" || fail "success did not report the four simulator cells"
    [ "$(cut -f 1 "$artifacts/results.tsv" | paste -sd, -)" = \
      ios-17,ios-18,ios-2026,ios-27 ] || fail "success narrowed the simulator matrix"
    [ "$(grep -c $'\tPASS\t' "$artifacts/results.tsv")" -eq 4 ] || fail "missing simulator PASS"
    [ "$(grep -c '^xcodebuild test-without-building ' "$fixture/calls.log")" -eq 16 ] || \
      fail "success did not repeat both corpora on all four simulators"
  else
    grep -q $'^apple\thardware-startup-no-vpn\tFAIL\t' "$fixture/matrix.tsv" || \
      fail "$mode failure became a passing aggregate"
  fi
  if [ "$mode" = cleanup-failure ] || [ "$mode" = ownership-mismatch ]; then
    [ -n "$(find "$artifacts/simulators" -name .cleanup-required -print -quit)" ] || \
      fail "$mode disarmed required cleanup"
  else
    [ "$(cat "$fixture/devices.tsv")" = \
      $'99999999-1111-2222-3333-444444444444\tuser-simulator' ] || \
      fail "$mode leaked an owned simulator or changed an existing simulator"
    [ -z "$(find "$artifacts/simulators" -name .cleanup-required -print -quit)" ] || \
      fail "$mode left cleanup armed after deletion"
  fi
  if [ "$mode" = ownership-mismatch ]; then
    ! grep -Eq '^xcrun simctl (shutdown|delete) ' "$fixture/calls.log" || \
      fail "cleanup mutated a simulator with a changed identity"
  fi
  if [ "$mode" = missing-runtime ]; then
    ! grep -Eq '^sdk build$|^xcodebuild build-for-testing |^xcrun simctl create ' "$fixture/calls.log" || \
      fail "an incomplete runtime matrix proceeded to build or create a simulator"
  fi
}

run_fixture success 0
run_fixture unit-failure 1
run_fixture ui-failure 1
run_fixture missing-runtime 1
run_fixture cleanup-failure 1
run_fixture ownership-mismatch 1
run_fixture terminate 130
echo 'apple simulator startup entry-point tests passed'
