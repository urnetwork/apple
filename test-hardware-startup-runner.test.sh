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
cat >"$test_root/bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Darwin\n' ;;
  -m)
    if [ "$APPLE_RUNNER_MODE" = unsupported-host ]; then
      printf 'x86_64\n'
    else
      printf 'arm64\n'
    fi
    ;;
  *) exit 98 ;;
esac
SH
cat >"$test_root/bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --foreground ] || shift
export APPLE_RUNNER_TIMEOUT="$1"
shift
exec "$@"
SH
cat >"$test_root/bin/ioreg" <<'SH'
#!/usr/bin/env bash
printf 'physical ioreg %s\n' "$*" >>"$APPLE_RUNNER_CALLS"
exit 97
SH
cat >"$test_root/bin/go" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${GOMAXPROCS:-}" = 2 ]
[ "${APPLE_RUNNER_TIMEOUT:-}" = 360 ]
[ "${UR_PROFILE_BOUNDARY_SOURCE_ROOT+x}" != x ]
[ "${UR_DEVICE_GENERATION_SOURCE_ROOT+x}" != x ]
[ "${UR_DEVICE_GENERATION_SANITIZER+x}" != x ]
apple_root="$(cd "$URNETWORK_ROOT/apple" && pwd)"
expected="test -p 1 -parallel 1 -count=1 $apple_root/test-vpn-profile-system_test.go $apple_root/test-split-tunnel-device-generation_test.go"
[ "$*" = "$expected" ] || {
  printf 'native test argv mismatch: expected [%s], got [%s]\n' "$expected" "$*" >&2
  exit 98
}
printf 'profile invariants\n' >>"$APPLE_RUNNER_CALLS"
[ "$APPLE_RUNNER_MODE" != profile-invariant-failure ] || exit 6
printf 'profile invariant fixture passed\n'
SH
cat >"$test_root/bin/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = build_apple ]
printf 'sdk build\n' >>"$APPLE_RUNNER_CALLS"
mkdir -p "$PWD/apple/URnetworkSdk.xcframework" \
  "$PWD/apple/URnetworkExtensionSdk.xcframework"
for sdk in URnetworkSdk URnetworkExtensionSdk; do
  framework="$PWD/apple/$sdk.xcframework/ios-arm64-simulator/$sdk.framework"
  mkdir -p "$framework"
  case "$APPLE_RUNNER_MODE:$sdk" in
    missing-app-slice:URnetworkSdk|missing-extension-slice:URnetworkExtensionSdk) ;;
    wrong-app-slice:URnetworkSdk|wrong-extension-slice:URnetworkExtensionSdk)
      printf 'x86_64\n' >"$framework/$sdk" ;;
    *) printf 'arm64\n' >"$framework/$sdk" ;;
  esac
done
SH
cat >"$test_root/bin/lipo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = -verify_arch ] && [ "$2" = arm64 ]
printf 'sdk slice-check %s\n' "${3##*/}" >>"$APPLE_RUNNER_CALLS"
[ -f "$3" ] && [ "$(cat "$3")" = arm64 ]
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
          | select(($mode != "missing-runtime" and ($mode | startswith("deferred") | not)) or . != "17.2")
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
              then "changed-owner" else .[1] end), state: (.[2] // "Booted"), isAvailable: true
          }
        ]}}' <"$APPLE_RUNNER_DEVICES"
        ;;
      *) exit 98 ;;
    esac
    ;;
  create)
    release="${2#urnetwork-acceptance-ios-}"
    release="${release%%-*}"
    count_file="$APPLE_RUNNER_DEVICES.create-count"
    create_count="$(cat "$count_file" 2>/dev/null || printf '0')"
    create_count=$((create_count + 1))
    printf '%s\n' "$create_count" >"$count_file"
    udid="$(printf '%08d-1111-2222-3333-%012d' "$release" "$create_count")"
    if [[ "$APPLE_RUNNER_MODE" == extension-generation-* ]] && \
       [ "$(wc -l <"$APPLE_RUNNER_DEVICES" | tr -d ' ')" -ne 1 ]; then
      echo 'fixture extension: next owner created before prior simulator deletion' >&2
      exit 65
    fi
    printf '%s\t%s\tShutdown\n' "$udid" "$2" >>"$APPLE_RUNNER_DEVICES"
    printf '%s\n' "$udid"
    ;;
  boot)
    awk -F '\t' -v OFS='\t' -v udid="$2" \
      '$1 == udid { $3 = "Booted" } { print }' "$APPLE_RUNNER_DEVICES" \
      >"$APPLE_RUNNER_DEVICES.tmp"
    mv "$APPLE_RUNNER_DEVICES.tmp" "$APPLE_RUNNER_DEVICES"
    ;;
  spawn) ;;
  shutdown)
    # Joining the simulator ends pending extension launches, including one
    # retained after xcodebuild has already returned its unit or UI result.
    [ "$APPLE_RUNNER_MODE" != extension-generation-shutdown-failure ] || exit 8
    rm -f -- "$APPLE_RUNNER_DEVICES.$2.pending-extension"
    printf '%s\n' "$2" >"$APPLE_RUNNER_DEVICES.$2.joined"
    awk -F '\t' -v OFS='\t' -v udid="$2" \
      '$1 == udid { $3 = "Shutdown" } { print }' "$APPLE_RUNNER_DEVICES" \
      >"$APPLE_RUNNER_DEVICES.tmp"
    mv "$APPLE_RUNNER_DEVICES.tmp" "$APPLE_RUNNER_DEVICES"
    ;;
  bootstatus)
    if [ "$APPLE_RUNNER_MODE" = terminate ]; then
      kill -TERM "$PPID"
    fi
    ;;
  delete)
    [ "$2" != 99999999-1111-2222-3333-444444444444 ] || exit 99
    case "$APPLE_RUNNER_MODE" in cleanup-failure|deferred-cleanup-failure|extension-generation-cleanup-failure) exit 8 ;; esac
    if [[ "$APPLE_RUNNER_MODE" == extension-generation-* ]]; then
      [ -f "$APPLE_RUNNER_DEVICES.$2.joined" ] || exit 65
      [ ! -f "$APPLE_RUNNER_DEVICES.$2.pending-extension" ] || exit 65
    fi
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
mode="" destination="" sdk="" derived="" build_id="" nonce="" xctestrun="" target="" arch="" arch_count=0
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
    ARCHS=*) arch="${1#*=}"; arch_count=$((arch_count + 1)) ;;
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
    if [ "$arch" != arm64 ] || [ "$arch_count" -ne 1 ]; then
      echo 'fixture link: generic simulator build requests x86_64 but SDK slice is arm64 only' >&2
      exit 65
    fi
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
    case "$APPLE_RUNNER_MODE" in
      extension-generation-unit-ui|extension-generation-repetition)
        # Force the observed ordering synchronously: an extension launch
        # still names the installed generation when the next action replaces
        # that app. The process needs no scheduler timing or negative wait.
        if [ -f "$APPLE_RUNNER_DEVICES.$udid.pending-extension" ]; then
          echo "fixture extension: Invalid bundle record for stale generation during $target" >&2
          exit 65
        fi
        if [ "$APPLE_RUNNER_MODE" = extension-generation-unit-ui ] || \
           [[ "$target" == networkUITests/* ]]; then
          printf '%s\n' "$target" >"$APPLE_RUNNER_DEVICES.$udid.pending-extension"
        fi
        ;;
    esac
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
  local expected_actions lane repetition corpus owner owner_out action_count owner_count
  local -a startup_args
  startup_args=()
  case "$mode" in deferred*) startup_args=(--defer-ios-17-2) ;; esac
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
  # The runner resolves its own directory; force a same-root alias so exact
  # native argv checks never depend on TMPDIR's spelling or trailing slash.
  env PATH="$test_root/bin:$PATH" URNETWORK_ROOT="$fixture/./" \
    URNETWORK_NETWORK_TEST_LOCK_HELD=1 UR_ACCEPT_APPLE_TOOLS="$fixture/tools" \
    WARP_VERSION=fixture UR_ACCEPT_REPEAT=2 UR_ACCEPT_RESULT_FILE="$fixture/matrix.tsv" \
    APPLE_RUNNER_MODE="$mode" APPLE_RUNNER_CALLS="$fixture/calls.log" \
    APPLE_RUNNER_DEVICES="$fixture/devices.tsv" \
    UR_PROFILE_BOUNDARY_SOURCE_ROOT=/untrusted-fixture/profile \
    UR_DEVICE_GENERATION_SOURCE_ROOT=/untrusted-fixture/device \
    UR_DEVICE_GENERATION_SANITIZER=untrusted-fixture \
    URNETWORK_RUN_ID=fixture-run URNETWORK_PLAN_SHA256=fixture-plan \
    URNETWORK_RUNNER_MAIN_COVERAGE_FILE="$fixture/coverage.json" \
    bash "$fixture/apple/test-hardware-startup.sh" ${startup_args[@]+"${startup_args[@]}"} >"$fixture/run.log" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    tail -n 12 "$fixture/run.log" >&2
    fail "$mode exited $status; expected $expected_status"
  fi
  if grep -q '^physical ' "$fixture/calls.log"; then
    fail "$mode contacted a physical iPhone command"
  fi
  if [ "$mode" = unsupported-host ]; then
    ! grep -q '^profile invariants$' "$fixture/calls.log" || \
      fail "unsupported host reached native profile invariants"
  else
    [ "$(grep -c '^profile invariants$' "$fixture/calls.log")" -eq 1 ] || \
      fail "$mode did not run both native profile invariant files exactly once"
  fi
  [ "$(wc -l <"$fixture/matrix.tsv" | tr -d ' ')" -eq 1 ] || \
    fail "$mode did not write exactly one aggregate result"
  artifacts="$(find "$fixture/apple/tests/__hardware_startup__" -mindepth 1 -maxdepth 1 -type d)"
  [ -d "$artifacts" ] || fail "$mode has no artifact directory"
  [ ! -e "$artifacts/device-plan.json" ] && \
    [ ! -e "$artifacts/real-device-matrix.md" ] || fail "$mode claimed physical proof"
  if [ "$mode" = deferred ]; then
    grep -q 'TAILORED coverage; ios-17/17.2 DEFERRED' "$fixture/matrix.tsv" || fail "deferral looked like full coverage"
    [ "$(cut -f 1 "$artifacts/results.tsv" | paste -sd, -)" = ios-18,ios-2026,ios-27 ] || fail "deferral changed another row"
    [ "$(grep -c '^xcodebuild test-without-building ' "$fixture/calls.log")" -eq 12 ] || fail "remaining corpora changed"
    ! grep -q -- '-downloadPlatform\|urnetwork-acceptance-ios-17-' "$fixture/calls.log" || fail "deferred row was provisioned"
    jq -e '.version == 1 and .run_id == "fixture-run" and .plan_sha256 == "fixture-plan"
      and .coverage_scope == "tailored-ios17.2-deferred" and .deferred == ["ios-17/17.2"]
      and .required == ["ios-18","ios-2026","ios-27"] and .passed and .cleanup_complete
      and (.runtime_plan_sha256 | test("^[a-f0-9]{64}$"))' "$fixture/coverage.json" >/dev/null || fail "missing coverage receipt"
    [ "$(jq -r .runtime_plan_sha256 "$fixture/coverage.json")" = "$(shasum -a 256 "$artifacts/simulator-plan.json" | awk '{print $1}')" ] || fail "runtime plan hash was not bound"
  elif [ "$expected_status" -eq 0 ]; then
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
  if [ "$expected_status" -ne 0 ] && [ -e "$fixture/coverage.json" ]; then
    fail "$mode published passing tailored coverage after failure"
  fi
  if [ "$mode" = cleanup-failure ] || [ "$mode" = deferred-cleanup-failure ] || \
     [ "$mode" = extension-generation-cleanup-failure ] || \
     [ "$mode" = extension-generation-shutdown-failure ] || [ "$mode" = ownership-mismatch ]; then
    [ -n "$(find "$artifacts/simulators" -name .cleanup-required -print -quit)" ] || \
      fail "$mode disarmed required cleanup"
  else
    [ "$(cat "$fixture/devices.tsv")" = \
      $'99999999-1111-2222-3333-444444444444\tuser-simulator' ] || \
      fail "$mode leaked an owned simulator or changed an existing simulator"
    [ -z "$(find "$artifacts/simulators" -name .cleanup-required -print -quit)" ] || \
      fail "$mode left cleanup armed after deletion"
  fi
  if [[ "$mode" == extension-generation-* ]]; then
    if [ "$mode" = extension-generation-cleanup-failure ] || \
       [ "$mode" = extension-generation-shutdown-failure ]; then
      [ "$(grep -c '^xcrun simctl create ' "$fixture/calls.log")" -eq 1 ] || \
        fail 'failed owner cleanup allowed another simulator creation'
      [ "$(grep -c '^xcodebuild test-without-building ' "$fixture/calls.log")" -eq 1 ] || \
        fail 'failed owner cleanup allowed another app installation'
      if [ "$mode" = extension-generation-shutdown-failure ]; then
        ! grep -q '^xcrun simctl delete ' "$fixture/calls.log" || \
          fail 'simulator deletion proceeded without joining the owner'
      fi
    fi
  fi
  if [ "$expected_status" -eq 0 ]; then
    # Keep both complete corpora on every selected release and repetition,
    # including the original full/deferred controls, with one owner per action.
    expected_actions=$((4 * $(jq 'length' "$artifacts/simulator-plan.json")))
    [ "$(grep -c '^xcrun simctl create ' "$fixture/calls.log")" -eq "$expected_actions" ] || \
      fail 'test actions did not each create a fresh simulator'
    [ "$(grep -c '^xcrun simctl shutdown ' "$fixture/calls.log")" -eq "$expected_actions" ] || \
      fail 'test actions did not each join their simulator'
    [ "$(grep -c '^xcrun simctl delete ' "$fixture/calls.log")" -eq "$expected_actions" ] || \
      fail 'test actions did not each delete their simulator'
    [ "$(wc -l <"$artifacts/owned-simulators.tsv" | tr -d ' ')" -eq "$expected_actions" ] || \
      fail 'ownership journal lost an action identity'
    while IFS= read -r lane; do
      jq -e --arg lane "$lane" '
        .version == 2 and .lane == $lane
        and .owners == [
          $lane + "-unit-1", $lane + "-ui-1",
          $lane + "-unit-2", $lane + "-ui-2"
        ]
      ' "$artifacts/simulators/$lane/identity.json" >/dev/null || \
        fail "$lane lost its exact action ownership plan"
      for repetition in 1 2; do
        [ -f "$artifacts/simulators/$lane/unit-test-$repetition.log" ] && \
          [ -f "$artifacts/simulators/$lane/test-$repetition.log" ] || \
          fail "$lane repetition $repetition lost a corpus artifact"
        for corpus in unit ui; do
          owner="$lane-$corpus-$repetition"
          owner_out="$artifacts/simulators/$owner"
          jq -e --arg lane "$lane" --arg owner "$owner" \
            --arg corpus "$corpus" --argjson repetition "$repetition" '
            .lane == $lane and .owner == $owner and .corpus == $corpus
            and .repetition == $repetition
          ' "$owner_out/identity.json" >/dev/null || \
            fail "$owner lost its exact simulator identity"
          grep -q $'\tPASS\ttested-and-deleted$' "$owner_out/action-status.tsv" || \
            fail "$owner lost its successful test and cleanup receipt"
        done
      done
    done < <(jq -r '.[].identifier' "$artifacts/simulator-plan.json")
  fi
  if [ "$mode" = ownership-mismatch ]; then
    ! grep -Eq '^xcrun simctl (shutdown|delete) ' "$fixture/calls.log" || \
      fail "cleanup mutated a simulator with a changed identity"
  fi
  if [ "$mode" = missing-runtime ]; then
    ! grep -Eq '^sdk build$|^xcodebuild build-for-testing |^xcrun simctl create ' "$fixture/calls.log" || \
      fail "an incomplete runtime matrix proceeded to build or create a simulator"
  fi
  if [ "$mode" = profile-invariant-failure ]; then
    grep -q 'native profile invariants failed' "$fixture/run.log" || \
      fail "native invariant failure omitted its diagnostic"
    ! grep -Eq '^sdk build$|^xcodebuild build-for-testing |^xcodebuild -downloadPlatform |^xcrun simctl ' \
      "$fixture/calls.log" || fail "failed native invariants reached provisioning, build or simulator access"
  fi
  case "$mode" in
    success|deferred)
      local profile_line inventory_line
      profile_line="$(grep -n '^profile invariants$' "$fixture/calls.log" | cut -d: -f1)"
      inventory_line="$(grep -n '^xcrun simctl list runtimes --json$' "$fixture/calls.log" | sed -n '1s/:.*//p')"
      [ "$profile_line" -lt "$inventory_line" ] || \
        fail "$mode inventoried runtimes before native profile invariants"
      grep -q '^profile invariant fixture passed$' "$artifacts/profile-boundary-test.log" || \
        fail "$mode omitted the native profile invariant log"
      [ "$(grep -c '^sdk slice-check ' "$fixture/calls.log")" -eq 2 ] || \
        fail "$mode did not verify both SDK arm64 simulator binaries"
      grep -q '^sdk slice-check URnetworkSdk$' "$fixture/calls.log" && \
        grep -q '^sdk slice-check URnetworkExtensionSdk$' "$fixture/calls.log" || \
        fail "$mode verified the wrong SDK binary"
      ;;
    unsupported-host)
      grep -q 'iOS simulator startup requires an arm64 host' "$fixture/run.log" || \
        fail "unsupported host did not fail at the architecture contract"
      ! grep -Eq '^sdk build$|^xcodebuild build-for-testing |^xcrun simctl ' "$fixture/calls.log" || \
        fail "unsupported host reached provisioning, SDK build, or simulator mutation"
      ;;
    missing-app-slice|missing-extension-slice|wrong-app-slice|wrong-extension-slice)
      grep -q 'local Apple SDK has no usable arm64 simulator binary' "$fixture/run.log" || \
        fail "$mode did not fail at SDK slice verification"
      ! grep -Eq '^xcodebuild build-for-testing |^xcrun simctl create ' "$fixture/calls.log" || \
        fail "$mode reached linking or simulator creation"
      ;;
  esac
  action_count="$(grep -c '^xcodebuild test-without-building ' "$fixture/calls.log" || true)"
  owner_count=0
  if [ -f "$artifacts/owned-simulators.tsv" ]; then
    owner_count="$(wc -l <"$artifacts/owned-simulators.tsv" | tr -d ' ')"
  fi
  printf 'apple simulator fixture passed: %s status=%s actions=%s owners=%s\n' \
    "$mode" "$status" "$action_count" "$owner_count"
}

if [ "$#" -ne 0 ]; then
  [ "$#" -eq 1 ] || fail "expected one fixture name"
  case "$1" in
    success|deferred|extension-generation-unit-ui|extension-generation-repetition) run_fixture "$1" 0 ;;
    extension-generation-cleanup-failure|extension-generation-shutdown-failure) run_fixture "$1" 1 ;;
    unsupported-host|missing-app-slice|missing-extension-slice|wrong-app-slice|wrong-extension-slice)
      run_fixture "$1" 1 ;;
    *) fail "unknown fixture name" ;;
  esac
  echo 'apple simulator architecture fixture passed'
  exit 0
fi

run_fixture success 0
run_fixture profile-invariant-failure 1
run_fixture deferred 0
run_fixture deferred-cleanup-failure 1
run_fixture unit-failure 1
run_fixture ui-failure 1
run_fixture missing-runtime 1
run_fixture cleanup-failure 1
run_fixture ownership-mismatch 1
run_fixture terminate 130
run_fixture unsupported-host 1
run_fixture missing-app-slice 1
run_fixture missing-extension-slice 1
run_fixture wrong-app-slice 1
run_fixture wrong-extension-slice 1
run_fixture extension-generation-unit-ui 0
run_fixture extension-generation-repetition 0
run_fixture extension-generation-cleanup-failure 1
run_fixture extension-generation-shutdown-failure 1
echo 'apple simulator startup entry-point tests passed'
