#!/usr/bin/env bash

# GNU timeout normally places its child in a separate process group. Keep long
# Apple builds and XCTest runs in the runner's foreground group so an interrupt
# reaches Xcode and the cleanup trap can shut down the simulator immediately.
run_apple_acceptance_timeout() {
  local timeout_bin="$1"
  shift
  "$timeout_bin" --foreground "$@"
}

# CoreSimulator's boot-complete state does not imply that host bridges such as
# simctl pbpaste are available. Simulator.app owns those bridges. A headless
# acceptance run still needs the application process, but it must neither show
# nor activate its window.
apple_acceptance_open_simulator() {
  local headless="$1" opener="${2:-open}"
  if [ "$headless" -eq 1 ]; then
    "$opener" -gj -a Simulator
  else
    "$opener" -a Simulator
  fi
}

# macOS UI testing asks the process responsible for xcodebuild to listen for
# and post input events. When either TCC grant is absent, XCTest waits a minute
# and reports only that automation mode timed out, before any app test starts.
apple_acceptance_macos_automation_ready() {
  local probe="${1:-swift}" result
  result="$("$probe" -e '
    import CoreGraphics
    print("listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())")
  ')" || return 1
  [ "$result" = "listen=true post=true" ] || {
    echo "[apple acceptance] macOS UI automation is unavailable ($result)" >&2
    echo "[apple acceptance] enable the terminal running xcodebuild in Privacy & Security > Accessibility and Input Monitoring, then restart it" >&2
    return 1
  }
}

apple_acceptance_test_runner_running() {
  local simulator_udid="$1" executable="$2"
  pgrep -f "/Devices/${simulator_udid}/.*/${executable}.app/${executable}$" >/dev/null
}

apple_acceptance_test_runner_installed() {
  local simulator_udid="$1" bundle_id="$2" executable="$3"
  local devices_root="${4:-${HOME}/Library/Developer/CoreSimulator/Devices}"
  local application_root app installed_bundle_id
  application_root="$devices_root/$simulator_udid/data/Containers/Bundle/Application"

  # Do not ask CoreSimulator whether Xcode installed the runner. The failure
  # this watchdog repairs is a blocked CoreSimulator launch RPC, and listapps
  # queues behind that same RPC indefinitely. Installation is already durable
  # on disk by this point, so inspect the exact bundle and identifier there.
  while IFS= read -r -d '' app; do
    installed_bundle_id="$(
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null
    )" || continue
    [ "$installed_bundle_id" = "$bundle_id" ] && return 0
  done < <(
    find "$application_root" -mindepth 2 -maxdepth 2 -type d \
      -name "${executable}.app" -print0 2>/dev/null
  )
  return 1
}

apple_acceptance_launch_test_runner() {
  local simulator_udid="$1" bundle_id="$2"
  timeout 15 xcrun simctl launch "$simulator_udid" "$bundle_id"
}

# Xcode 17 can install an iOS UI-test runner and then wait forever in
# SimDevice.launchApplication. Only kick the exact boundary where the bundle is
# installed but its process is absent. If Xcode launches normally this is a
# no-op; activating an already-running process is never used as a success path.
apple_acceptance_kick_test_runner_if_needed() {
  local simulator_udid="$1" bundle_id="$2" executable="$3"
  local running_probe="${4:-apple_acceptance_test_runner_running}"
  local installed_probe="${5:-apple_acceptance_test_runner_installed}"
  local launcher="${6:-apple_acceptance_launch_test_runner}"

  "$running_probe" "$simulator_udid" "$executable" && return 0
  "$installed_probe" "$simulator_udid" "$bundle_id" "$executable" || return 1
  "$launcher" "$simulator_udid" "$bundle_id"
}

apple_acceptance_watch_test_runner() {
  local simulator_udid="$1" bundle_id="$2" executable="$3"
  local initial_delay="${4:-30}" attempts="${5:-60}"
  local attempt

  for ((attempt = 0; attempt < initial_delay; attempt += 1)); do
    sleep 1
  done
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if apple_acceptance_test_runner_running "$simulator_udid" "$executable"; then
      return 0
    fi
    if apple_acceptance_test_runner_installed "$simulator_udid" "$bundle_id" "$executable"; then
      echo "[apple acceptance] UI-test runner is installed but not running; applying CoreSimulator launch kick"
      apple_acceptance_launch_test_runner "$simulator_udid" "$bundle_id"
      return $?
    fi
    sleep 2
  done
  echo "[apple acceptance] UI-test runner was not installed before the launch-watch deadline" >&2
  return 1
}

apple_acceptance_remove_temp_tree() {
  local target="${1:-}" temp_root="${2:-}"
  if [ "$temp_root" != / ]; then
    temp_root="${temp_root%/}"
  fi
  case "$target" in
    "$temp_root"/urnetwork-apple-clipboard.*) ;;
    *)
      echo "[apple acceptance] refusing to remove unexpected temporary path: $target" >&2
      return 2
      ;;
  esac

  [ -e "$target" ] || return 0
  # Go deliberately makes downloaded module directories read-only. Restore
  # owner write permission before removing the private per-run module cache.
  chmod -R u+w "$target" || return 1
  rm -rf -- "$target"
}
