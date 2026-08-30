#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/test-main-lib.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-cleanup-test.XXXXXX")"
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

foreground_timeout_seen=0
fake_foreground_timeout() {
  [ "$1" = --foreground ] || {
    echo "timeout child was not kept in the foreground process group" >&2
    return 1
  }
  foreground_timeout_seen=1
  shift
  shift
  "$@"
}
run_apple_acceptance_timeout fake_foreground_timeout 30 true
[ "$foreground_timeout_seen" -eq 1 ] || {
  echo "foreground timeout wrapper was not called" >&2
  exit 1
}

simulator_open_args=""
fake_open() {
  simulator_open_args="$*"
}
apple_acceptance_open_simulator 1 fake_open
[ "$simulator_open_args" = "-gj -a Simulator" ] || {
  echo "headless runner did not launch Simulator hidden and without activation: $simulator_open_args" >&2
  exit 1
}
apple_acceptance_open_simulator 0 fake_open
[ "$simulator_open_args" = "-a Simulator" ] || {
  echo "headed runner did not launch Simulator normally: $simulator_open_args" >&2
  exit 1
}

fake_automation_granted() {
  [ "$1" = -e ] || return 1
  printf 'listen=true post=true\n'
}
apple_acceptance_macos_automation_ready fake_automation_granted || {
  echo "granted macOS automation permissions were rejected" >&2
  exit 1
}

fake_automation_denied() {
  [ "$1" = -e ] || return 1
  printf 'listen=false post=false\n'
}
automation_error="$test_root/automation-error.log"
if apple_acceptance_macos_automation_ready fake_automation_denied 2>"$automation_error"; then
  echo "denied macOS automation permissions were accepted" >&2
  exit 1
fi
grep -q 'Accessibility and Input Monitoring' "$automation_error" || {
  echo "macOS automation failure omitted its remediation" >&2
  exit 1
}

runner_present=0
runner_installed=1
runner_launch_args=""
fake_runner_probe() {
  [ "$runner_present" -eq 1 ]
}
fake_installed_probe() {
  [ "$runner_installed" -eq 1 ]
}
fake_runner_launcher() {
  runner_launch_args="$*"
}

apple_acceptance_kick_test_runner_if_needed \
  SIMULATOR-ID network.ur.networkUITests.xctrunner networkUITests-Runner \
  fake_runner_probe fake_installed_probe fake_runner_launcher
[ "$runner_launch_args" = "SIMULATOR-ID network.ur.networkUITests.xctrunner" ] || {
  echo "installed-but-absent UI-test runner did not receive the launch kick" >&2
  exit 1
}

runner_present=1
runner_launch_args=""
apple_acceptance_kick_test_runner_if_needed \
  SIMULATOR-ID network.ur.networkUITests.xctrunner networkUITests-Runner \
  fake_runner_probe fake_installed_probe fake_runner_launcher
[ -z "$runner_launch_args" ] || {
  echo "already-running UI-test runner was launched again" >&2
  exit 1
}

runner_present=0
runner_installed=0
if apple_acceptance_kick_test_runner_if_needed \
  SIMULATOR-ID network.ur.networkUITests.xctrunner networkUITests-Runner \
  fake_runner_probe fake_installed_probe fake_runner_launcher; then
  echo "missing UI-test runner was treated as launchable" >&2
  exit 1
fi

simulator_id="SIMULATOR-ID"
runner_root="$test_root/devices/$simulator_id/data/Containers/Bundle/Application/APP-ID/networkUITests-Runner.app"
mkdir -p "$runner_root"
plutil -create xml1 "$runner_root/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Add :CFBundleIdentifier string network.ur.networkUITests.xctrunner' \
  "$runner_root/Info.plist"
apple_acceptance_test_runner_installed \
  "$simulator_id" network.ur.networkUITests.xctrunner networkUITests-Runner \
  "$test_root/devices" || {
    echo "installed UI-test runner was not found from its on-disk bundle" >&2
    exit 1
  }
if apple_acceptance_test_runner_installed \
  "$simulator_id" network.ur.wrong.xctrunner networkUITests-Runner \
  "$test_root/devices"; then
  echo "on-disk UI-test runner accepted the wrong bundle identifier" >&2
  exit 1
fi

readonly_tree="$test_root/urnetwork-apple-clipboard.readonly"
mkdir -p "$readonly_tree/go-mod-cache/example/module"
printf 'cached module\n' >"$readonly_tree/go-mod-cache/example/module/go.mod"
chmod 0444 "$readonly_tree/go-mod-cache/example/module/go.mod"
chmod 0555 "$readonly_tree/go-mod-cache/example/module"
chmod 0555 "$readonly_tree/go-mod-cache/example"
chmod 0555 "$readonly_tree/go-mod-cache"

apple_acceptance_remove_temp_tree "$readonly_tree" "$test_root"
[ ! -e "$readonly_tree" ] || {
  echo "read-only Go module cache was not removed" >&2
  exit 1
}

unrelated="$test_root/not-an-acceptance-tree"
mkdir "$unrelated"
if apple_acceptance_remove_temp_tree "$unrelated" "$test_root" 2>/dev/null; then
  echo "cleanup accepted a path outside its private naming contract" >&2
  exit 1
fi
[ -d "$unrelated" ] || {
  echo "cleanup removed an unrelated path" >&2
  exit 1
}

echo "apple acceptance runner tests passed"
