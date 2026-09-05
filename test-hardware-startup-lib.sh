#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

apple_hardware_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

apple_hardware_write_inventory_plan() {
  local inventory="$1" plan="$2" skips="$3"
  local minimum_major="$4" minimum_minor="$5"
  local combined="${plan}.combined.tmp" plan_temporary="${plan}.tmp"
  local skips_temporary="${skips}.tmp"
  case "$minimum_major:$minimum_minor" in
    *[!0-9:]*|:*|*:) return 2 ;;
  esac

  jq -e \
    --argjson minimum_major "$minimum_major" \
    --argjson minimum_minor "$minimum_minor" '
    def version:
      .operatingSystemVersion
      | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)")
      | {major: (.major | tonumber), minor: (.minor | tonumber)};
    def version_is_supported:
      .version.major > $minimum_major
      or (
        .version.major == $minimum_major
        and .version.minor >= $minimum_minor
      );

    if type != "array" then
      error("xcdevice inventory is not an array")
    else . end
    | [
        .[]
        | select(
            .platform == "com.apple.platform.iphoneos"
            and .available == true
          )
      ] as $devices
    | if any($devices[];
        .simulator != false
        or (.identifier | type) != "string"
        or (.identifier | test("^[A-Za-z0-9-]+$") | not)
        or (.name | type) != "string"
        or (.name | length) == 0
        or (.name | test("[\u0000-\u001f]") == true)
        or (.modelName | type) != "string"
        or (.modelName | length) == 0
        or (.modelName | test("[\u0000-\u001f]") == true)
        or (.operatingSystemVersion | type) != "string"
        or (.operatingSystemVersion | length) == 0
        or (.operatingSystemVersion | test("[\u0000-\u001f]") == true)
        or (.architecture | type) != "string"
        or (.architecture | test("^arm64(e)?$") | not)
        or ((.interface? // "") | IN("usb", "network") | not)
        or .ignored != false
        or ((.error? // null) != null)
        or (try version catch null) == null
      ) then
        error("available physical iOS inventory contains an ignored or malformed device")
      elif any(
        ($devices | group_by(.identifier))[];
        length != 1
      ) then
        error("physical iOS inventory contains a duplicate device identifier")
      else
        ($devices | map(. + {version: version})) as $versioned
        | ($versioned | map(select(version_is_supported))) as $eligible
        | {
            plan: (
              $eligible
              | map({
                  identifier,
                  name,
                  modelName,
                  operatingSystemVersion,
                  architecture,
                  interface
                })
              | sort_by(.identifier)
            ),
            skips: (
              $versioned
              | map(select(version_is_supported | not))
              | map({
                  identifier,
                  name,
                  operatingSystemVersion,
                  reason: (
                    "requires-ios-"
                    + ($minimum_major | tostring)
                    + "."
                    + ($minimum_minor | tostring)
                  )
                })
              | sort_by(.identifier)
            )
          }
      end
  ' "$inventory" >"$combined" || {
    rm -f "$combined" "$plan_temporary" "$skips_temporary"
    return 1
  }

  if ! jq -e '.plan' "$combined" >"$plan_temporary" || \
     ! jq -r '.skips[] | [
            .identifier,
            .name,
            .operatingSystemVersion,
            .reason
          ] | @tsv' "$combined" >"$skips_temporary"; then
    rm -f "$combined" "$plan_temporary" "$skips_temporary"
    return 1
  fi
  rm -f "$combined"
  mv "$plan_temporary" "$plan"
  mv "$skips_temporary" "$skips"
}

# Keep the user-facing release labels separate from Apple's runtime majors.
# Apple named the release following iOS 18 "iOS 26"; the acceptance request
# calls that generation "2026", so ios-2026 deliberately maps to major 26.
apple_ios_required_simulator_releases() {
  printf '%s\n' \
    $'ios-16\t16\t16.4' \
    $'ios-17\t17\t17.2' \
    $'ios-18\t18\t18.5' \
    $'ios-2026\t26\t26.5'
}

apple_ios_runtime_major_available() {
  local inventory="$1" major="$2"
  case "$major" in ''|*[!0-9]*) return 2 ;; esac

  jq -e --argjson major "$major" '
    def runtime_major:
      .version
      | capture("^(?<major>[0-9]+)\\.[0-9]+(?:\\.[0-9]+)?$")
      | .major
      | tonumber;
    (.runtimes | type) == "array"
    and any(
      .runtimes[];
      .platform == "iOS"
      and .isAvailable == true
      and (try runtime_major catch -1) == $major
      and (.supportedDeviceTypes | type) == "array"
      and any(
        .supportedDeviceTypes[];
        .productFamily == "iPhone"
        and (.name | type) == "string"
        and (.name | startswith("iPhone"))
        and (.identifier | type) == "string"
        and (.identifier | test("^com\\.apple\\.CoreSimulator\\.SimDeviceType\\.[A-Za-z0-9-]+$"))
      )
    )
  ' "$inventory" >/dev/null
}

apple_ios_missing_simulator_downloads() {
  local inventory="$1" lane major download_version
  jq -e '(.runtimes | type) == "array"' "$inventory" >/dev/null || return 1

  while IFS=$'\t' read -r lane major download_version; do
    if ! apple_ios_runtime_major_available "$inventory" "$major"; then
      printf '%s\t%s\t%s\n' "$lane" "$major" "$download_version"
    fi
  done < <(apple_ios_required_simulator_releases)
}

apple_ios_download_missing_simulator_runtimes() {
  local inventory="$1" logs_dir="$2" architecture_variant="${3:-default}"
  local lane major download_version log
  local -a download_command
  case "$architecture_variant" in default|arm64|universal) ;; *) return 2 ;; esac
  [ -d "$logs_dir" ] && [ ! -L "$logs_dir" ] || return 2

  while IFS=$'\t' read -r lane major download_version; do
    [ -n "$lane" ] || continue
    log="$logs_dir/$lane-download.log"
    [ ! -e "$log" ] && [ ! -L "$log" ] || return 2
    echo "[apple iOS devices] installing the iOS $download_version simulator runtime"
    download_command=(
      timeout --foreground 10800 xcodebuild
      -downloadPlatform iOS
      -buildVersion "$download_version"
    )
    if [ "$architecture_variant" != default ]; then
      download_command+=(
        -architectureVariant "$architecture_variant"
      )
    fi
    if ! "${download_command[@]}" >"$log" 2>&1; then
      return 1
    fi
    chmod 600 "$log"
  done < <(apple_ios_missing_simulator_downloads "$inventory")
}

apple_ios_write_simulator_runtime_plan() {
  local inventory="$1" plan="$2" temporary
  temporary="${plan}.tmp"
  [ ! -L "$plan" ] || return 2
  [ ! -e "$temporary" ] || return 2

  if ! jq -e '
    def required:
      [
        {identifier: "ios-16", requestedRelease: "16", major: 16, downloadVersion: "16.4"},
        {identifier: "ios-17", requestedRelease: "17", major: 17, downloadVersion: "17.2"},
        {identifier: "ios-18", requestedRelease: "18", major: 18, downloadVersion: "18.5"},
        {identifier: "ios-2026", requestedRelease: "2026", major: 26, downloadVersion: "26.5"}
      ];
    def parsed_version:
      .version
      | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)(?:\\.(?<patch>[0-9]+))?$")
      | [
          (.major | tonumber),
          (.minor | tonumber),
          ((.patch // "0") | tonumber)
        ];
    def valid_runtime:
      .platform == "iOS"
      and .isAvailable == true
      and (.version | type) == "string"
      and (try parsed_version catch null) != null
      and (.buildversion | type) == "string"
      and (.buildversion | test("^[A-Za-z0-9]+$"))
      and (.identifier | type) == "string"
      and (.identifier | test("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS-[0-9-]+$"))
      and (.supportedDeviceTypes | type) == "array";
    def compatible_iphones:
      [
        .supportedDeviceTypes[]
        | select(
            .productFamily == "iPhone"
            and (.name | type) == "string"
            and (.name | startswith("iPhone"))
            and (.identifier | type) == "string"
            and (.identifier | test("^com\\.apple\\.CoreSimulator\\.SimDeviceType\\.[A-Za-z0-9-]+$"))
          )
      ];

    if type != "object" or (.runtimes | type) != "array" then
      error("simctl runtime inventory is malformed")
    else . end
    | .runtimes as $runtimes
    | [
        required[] as $required
        | ([
            $runtimes[]
            | select(valid_runtime)
            | . + {parsedVersion: parsed_version}
            | select(.parsedVersion[0] == $required.major)
            | select((compatible_iphones | length) > 0)
          ] | sort_by([.parsedVersion, .buildversion, .identifier]) | last) as $runtime
        | if $runtime == null then
            error("required iOS simulator runtime is unavailable: " + $required.identifier)
          else
            ($runtime | compatible_iphones | first) as $device_type
            | {
                identifier: $required.identifier,
                requestedRelease: $required.requestedRelease,
                runtimeMajor: $required.major,
                downloadVersion: $required.downloadVersion,
                runtimeVersion: $runtime.version,
                runtimeBuildVersion: $runtime.buildversion,
                runtimeIdentifier: $runtime.identifier,
                deviceTypeIdentifier: $device_type.identifier,
                deviceTypeName: $device_type.name
              }
          end
      ]
  ' "$inventory" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  mv "$temporary" "$plan"
}

apple_ios_runtime_plan_supports_deployment_target() {
  local plan="$1" minimum_major="$2" minimum_minor="$3"
  case "$minimum_major:$minimum_minor" in
    *[!0-9:]*|:*|*:) return 2 ;;
  esac
  jq -e \
    --argjson minimum_major "$minimum_major" \
    --argjson minimum_minor "$minimum_minor" '
    def version:
      .runtimeVersion
      | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)(?:\\.[0-9]+)?$")
      | {major: (.major | tonumber), minor: (.minor | tonumber)};
    type == "array"
    and length == 4
    and all(
      .[];
      (try version catch null) as $version
      | $version != null
        and (
          $version.major > $minimum_major
          or (
            $version.major == $minimum_major
            and $version.minor >= $minimum_minor
          )
        )
    )
  ' "$plan" >/dev/null
}

apple_ios_simulator_udid_is_valid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

apple_ios_simulator_lane_is_valid() {
  case "$1" in ios-16|ios-17|ios-18|ios-2026) return 0 ;; esac
  return 1
}

apple_ios_simulator_name_is_valid() {
  local lane="$1" name="$2" release
  apple_ios_simulator_lane_is_valid "$lane" || return 1
  release="${lane#ios-}"
  [[ "$name" =~ ^urnetwork-acceptance-ios-${release}-[0-9]{8}-[0-9]{6}Z$ ]]
}

apple_ios_validate_owned_simulator_journal() {
  local journal="$1" lane udid name extra
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 2

  while IFS=$'\t' read -r lane udid name extra || \
      [ -n "$lane$udid$name$extra" ]; do
    [ -z "$extra" ] || return 1
    apple_ios_simulator_lane_is_valid "$lane" || return 1
    apple_ios_simulator_udid_is_valid "$udid" || return 1
    apple_ios_simulator_name_is_valid "$lane" "$name" || return 1
  done <"$journal"

  awk -F '\t' '
    NF != 3 { exit 1 }
    seen_lane[$1]++ || seen_udid[$2]++ { exit 1 }
    END { if (NR == 0) exit 1 }
  ' "$journal"
}

apple_ios_append_owned_simulator() {
  local journal="$1" lane="$2" udid="$3" name="$4"
  local temporary="${journal}.tmp"
  apple_ios_simulator_lane_is_valid "$lane" || return 2
  apple_ios_simulator_udid_is_valid "$udid" || return 2
  apple_ios_simulator_name_is_valid "$lane" "$name" || return 2
  [ ! -L "$journal" ] && [ ! -e "$temporary" ] || return 2

  if [ -e "$journal" ]; then
    apple_ios_validate_owned_simulator_journal "$journal" || return 1
    cp -p "$journal" "$temporary" || return 1
    if awk -F '\t' -v lane="$lane" -v udid="$udid" \
      '$1 == lane || $2 == udid { found = 1 } END { exit(found ? 0 : 1) }' \
      "$journal"; then
      rm -f -- "$temporary"
      return 1
    fi
  else
    (set -C; : >"$temporary") || return 1
  fi

  if ! printf '%s\t%s\t%s\n' "$lane" "$udid" "$name" >>"$temporary" || \
     ! apple_ios_validate_owned_simulator_journal "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary"
  mv "$temporary" "$journal"
}

apple_ios_owned_simulator_journal_has_identity() {
  local journal="$1" lane="$2" udid="$3" name="$4"
  apple_ios_validate_owned_simulator_journal "$journal" || return 2
  awk -F '\t' \
    -v lane="$lane" -v udid="$udid" -v name="$name" '
      $1 == lane && $2 == udid && $3 == name { matches++ }
      END { exit(matches == 1 ? 0 : 1) }
    ' "$journal"
}

apple_ios_simulator_inventory_contains_udid() {
  local inventory="$1" udid="$2"
  apple_ios_simulator_udid_is_valid "$udid" || return 2
  jq -e --arg udid "$udid" '
    (.devices | type) == "object"
    and any(
      [.devices[] | .[]][];
      (.udid | type) == "string" and .udid == $udid
    )
  ' "$inventory" >/dev/null
}

apple_ios_simulator_inventory_matches_identity() {
  local inventory="$1" udid="$2" name="$3"
  apple_ios_simulator_udid_is_valid "$udid" || return 2
  case "$name" in ''|*[!A-Za-z0-9-]*) return 2 ;; esac
  jq -e --arg udid "$udid" --arg name "$name" '
    (.devices | type) == "object"
    and ([
      [.devices[] | .[]][]
      | select((.udid | type) == "string" and .udid == $udid)
    ]) as $matches
    | ($matches | length) == 1
      and ($matches[0].name | type) == "string"
      and $matches[0].name == $name
      and ($matches[0].isAvailable | type) == "boolean"
      and $matches[0].isAvailable == true
  ' "$inventory" >/dev/null
}

apple_ios_capture_simulator_device_inventory() {
  local output="$1" temporary
  temporary="${output}.tmp"
  [ ! -e "$output" ] && [ ! -e "$temporary" ] && [ ! -L "$output" ] || \
    return 2
  if ! timeout --foreground 30 xcrun simctl list devices --json >"$temporary" || \
     ! jq -e '(.devices | type) == "object"' "$temporary" >/dev/null; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary"
  mv "$temporary" "$output"
}

apple_ios_cleanup_owned_simulators() {
  local journal="$1" results_root="$2" cleanup_log="$3"
  local temporary="${cleanup_log}.tmp" lane udid name marker lane_root
  local before after detail cleanup_tag status=0
  apple_ios_validate_owned_simulator_journal "$journal" || return 2
  [ -d "$results_root" ] && [ ! -L "$results_root" ] || return 2
  [ ! -e "$cleanup_log" ] && [ ! -e "$temporary" ] && \
    [ ! -L "$cleanup_log" ] || return 2
  cleanup_tag="$(basename "$cleanup_log")"
  cleanup_tag="${cleanup_tag%.tsv}"
  case "$cleanup_tag" in ''|*[!A-Za-z0-9-]*) return 2 ;; esac
  (set -C; : >"$temporary") || return 1

  while IFS=$'\t' read -r lane udid name; do
    lane_root="$results_root/$lane"
    marker="$lane_root/.cleanup-required"
    [ -f "$marker" ] || continue
    before="$lane_root/$cleanup_tag-devices-before.json"
    after="$lane_root/$cleanup_tag-devices-after.json"
    detail=shutdown-and-deleted

    if ! apple_ios_capture_simulator_device_inventory "$before"; then
      detail="inventory-before-unavailable"
    elif apple_ios_simulator_inventory_contains_udid "$before" "$udid"; then
      if ! apple_ios_simulator_inventory_matches_identity \
        "$before" "$udid" "$name"; then
        detail="owned-identity-mismatch"
      else
        timeout --foreground 30 xcrun simctl shutdown "$udid" \
          >"$lane_root/cleanup-shutdown.log" 2>&1 || true
        if ! timeout --foreground 30 xcrun simctl delete "$udid" \
          >"$lane_root/cleanup-delete.log" 2>&1; then
          detail="delete-failed"
        fi
      fi
    else
      detail="already-absent"
    fi

    if [ "$detail" = shutdown-and-deleted ] || \
       [ "$detail" = already-absent ]; then
      if ! apple_ios_capture_simulator_device_inventory "$after"; then
        detail="inventory-after-unavailable"
      elif apple_ios_simulator_inventory_contains_udid "$after" "$udid"; then
        detail="still-present-after-delete"
      else
        rm -f -- "$marker"
      fi
    fi

    if [ -f "$marker" ]; then
      printf '%s\t%s\tFAIL\t%s\n' "$lane" "$udid" "$detail" \
        >>"$temporary"
      status=1
    else
      printf '%s\t%s\tPASS\t%s\n' "$lane" "$udid" "$detail" \
        >>"$temporary"
    fi
  done <"$journal"

  chmod 600 "$temporary"
  mv "$temporary" "$cleanup_log"
  return "$status"
}

apple_hardware_usb_inventory_is_represented() {
  local inventory="$1" usb_identifiers="$2"

  jq -n -e \
    --rawfile usb_identifiers "$usb_identifiers" \
    --slurpfile inventory "$inventory" '
    ($usb_identifiers
      | split("\n")
      | map(select(length > 0))) as $identifiers
    | ($identifiers | length) == ($identifiers | unique | length)
      and all($identifiers[];
        . as $identifier
        | ([
            $inventory[0][]
            | select(
                .platform == "com.apple.platform.iphoneos"
                and .simulator == false
                and .identifier == $identifier
              )
          ]) as $matches
        | ($matches | length) == 1
          and $matches[0].available == true
          and $matches[0].ignored == false
          and (($matches[0].error? // null) == null)
      )
  ' >/dev/null
}

apple_hardware_write_usb_identifiers() {
  local ioreg_inventory="$1" output="$2" temporary
  local raw_identifier normalized_identifier
  temporary="${output}.tmp"

  : >"$temporary" || return 1
  while IFS= read -r raw_identifier; do
    if [[ "$raw_identifier" =~ ^[0-9A-Fa-f]{24}$ ]]; then
      normalized_identifier="${raw_identifier:0:8}-${raw_identifier:8}"
    elif [[ "$raw_identifier" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      normalized_identifier="$raw_identifier"
    else
      rm -f "$temporary"
      return 1
    fi
    printf '%s\n' "$normalized_identifier" >>"$temporary" || {
      rm -f "$temporary"
      return 1
    }
  done < <(awk -F '"' '/"USB Serial Number" = / { print $4 }' "$ioreg_inventory")

  LC_ALL=C sort -u "$temporary" -o "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  mv "$temporary" "$output"
}

apple_hardware_plan_ids() {
  jq -er '.[] | .identifier' "$1"
}

apple_hardware_plan_count() {
  jq -er 'length' "$1"
}

apple_hardware_markdown_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g'
}

apple_hardware_write_real_device_matrix() {
  local plan="$1" output="$2" temporary="${2}.tmp"
  local count model version label
  [ ! -e "$output" ] && [ ! -e "$temporary" ] && [ ! -L "$output" ] || \
    return 2
  count="$(apple_hardware_plan_count "$plan")" || return 1

  {
    printf '# iOS real-device acceptance matrix\n\n'
    if [ "$count" -eq 0 ]; then
      printf '_No eligible physical iOS devices are attached; no real-device cells run._\n'
    else
      printf '| Acceptance test |'
      while IFS=$'\t' read -r model version; do
        label="$(apple_hardware_markdown_escape "$model / iOS $version")"
        printf ' %s |' "$label"
      done < <(jq -r '.[] | [.modelName, .operatingSystemVersion] | @tsv' "$plan")
      printf '\n| --- |'
      while IFS= read -r _; do
        printf ' --- |'
      done < <(apple_hardware_plan_ids "$plan")
      printf "\n| \`networkTests\` deterministic no-VPN corpus |"
      while IFS= read -r _; do
        printf ' RUN |'
      done < <(apple_hardware_plan_ids "$plan")
      printf "\n| \`HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess\` |"
      while IFS= read -r _; do
        printf ' RUN |'
      done < <(apple_hardware_plan_ids "$plan")
      printf '\n'
    fi
  } >"$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 600 "$temporary"
  mv "$temporary" "$output"
}

apple_hardware_inventory_unchanged() {
  local inventory="$1" expected_hash="$2"
  [ "$(apple_hardware_sha256 "$inventory")" = "$expected_hash" ]
}

apple_hardware_lock_state_is_unlocked() {
  local lock_state="$1" expected_identifier="$2"
  case "$expected_identifier" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac

  jq -e --arg expected_identifier "$expected_identifier" '
    (.info | type) == "object"
    and .info.outcome == "success"
    and .info.commandType == "devicectl.device.info.lockState"
    and (.result | type) == "object"
    and (.result.deviceIdentifier | type) == "string"
    and .result.deviceIdentifier == $expected_identifier
    and (.result.passcodeRequired | type) == "boolean"
    and .result.passcodeRequired == false
    and (.result.unlockedSinceBoot | type) == "boolean"
    and .result.unlockedSinceBoot == true
  ' "$lock_state" >/dev/null
}

apple_hardware_device_details_are_usable() {
  local details="$1" expected_udid="$2"
  case "$expected_udid" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac

  jq -e --arg expected_udid "$expected_udid" '
    (.info | type) == "object"
    and .info.outcome == "success"
    and .info.commandType == "devicectl.device.info.details"
    and (.result | type) == "object"
    and (.result.identifier | type) == "string"
    and (.result.identifier | test("^[A-Za-z0-9-]+$"))
    and (.result.hardwareProperties | type) == "object"
    and .result.hardwareProperties.reality == "physical"
    and (.result.hardwareProperties.udid | type) == "string"
    and .result.hardwareProperties.udid == $expected_udid
    and (.result.connectionProperties | type) == "object"
    and .result.connectionProperties.pairingState == "paired"
    and (.result.deviceProperties | type) == "object"
    and .result.deviceProperties.bootState == "booted"
    and .result.deviceProperties.developerModeStatus == "enabled"
    and (.result.deviceProperties.ddiServicesAvailable | type) == "boolean"
    and .result.deviceProperties.ddiServicesAvailable == true
  ' "$details" >/dev/null
}

apple_hardware_device_details_identifier() {
  jq -er '
    .result.identifier
    | select(type == "string" and test("^[A-Za-z0-9-]+$"))
  ' "$1"
}

apple_hardware_app_query_is_clean() {
  local query="$1" bundle_id="$2"
  jq -e --arg bundle_id "$bundle_id" '
    (.info | type) == "object"
    and .info.outcome == "success"
    and (.result | type) == "object"
    and (.result.apps | type) == "array"
    and all(.result.apps[]; .bundleIdentifier != $bundle_id)
  ' "$query" >/dev/null
}

apple_hardware_app_query_has_bundle() {
  local query="$1" bundle_id="$2"
  jq -e --arg bundle_id "$bundle_id" '
    (.info | type) == "object"
    and .info.outcome == "success"
    and (.result | type) == "object"
    and (.result.apps | type) == "array"
    and any(.result.apps[]; .bundleIdentifier == $bundle_id)
  ' "$query" >/dev/null
}

apple_hardware_write_result_once() {
  local path="$1" device_id="$2" status="$3" detail="$4"
  case "$device_id" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac
  case "$status" in
    PASS|FAIL) ;;
    *) return 2 ;;
  esac
  (set -C; printf '%s\t%s\t%s\n' "$device_id" "$status" "$detail" >"$path")
}

apple_hardware_results_match_plan() {
  local plan="$1" results_root="$2" expected_count actual_count=0
  local device_id status_file recorded_id status detail
  expected_count="$(apple_hardware_plan_count "$plan")" || return 1

  while IFS= read -r device_id; do
    case "$device_id" in
      ''|*[!A-Za-z0-9-]*) return 1 ;;
    esac
    status_file="$results_root/$device_id/status.tsv"
    [ -f "$status_file" ] || return 1
    IFS=$'\t' read -r recorded_id status detail <"$status_file" || return 1
    [ "$recorded_id" = "$device_id" ] || return 1
    case "$status" in PASS|FAIL) ;; *) return 1 ;; esac
    [ -n "$detail" ] || return 1
    [ "$(wc -l <"$status_file" | tr -d ' ')" = 1 ] || return 1
    actual_count=$((actual_count + 1))
  done < <(apple_hardware_plan_ids "$plan")

  [ "$actual_count" -eq "$expected_count" ] || return 1
  [ "$(find "$results_root" -mindepth 2 -maxdepth 2 -name status.tsv -type f | wc -l | tr -d ' ')" -eq "$expected_count" ]
}

apple_hardware_prepare_xctestrun() {
  local source="$1" output="$2" nonce="$3" device_id="$4"
  local source_json="${output}.source.tmp" output_json="${output}.output.tmp"
  local source_directory output_directory
  case "$nonce" in
    ????????-*) return 2 ;;
    ''|*[!0-9a-f]*) return 2 ;;
  esac
  [ "${#nonce}" -eq 32 ] || return 2
  case "$device_id" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac
  [ -f "$source" ] || return 2
  [ ! -e "$output" ] || return 2
  source_directory="$(cd "$(dirname "$source")" && pwd -P)" || return 2
  output_directory="$(cd "$(dirname "$output")" && pwd -P)" || return 2
  # Xcode resolves every __TESTROOT__ token relative to the xctestrun file.
  # Moving the rewritten file would silently point it away from the freshly
  # built products, so location is part of the launch contract.
  [ "$source_directory" = "$output_directory" ] || return 2

  if ! /usr/bin/plutil -convert json -o "$source_json" "$source" || \
     ! jq -e --arg nonce "$nonce" --arg device_id "$device_id" '
      if (
        .["__xctestrun_metadata__"].FormatVersion == 2
        and (.TestConfigurations | type) == "array"
        and (.TestConfigurations | length) == 1
        and .TestConfigurations[0].IsEnabled == true
        and (.TestConfigurations[0].TestTargets | type) == "array"
        and ([
          .TestConfigurations[0].TestTargets[].BlueprintName
        ] | sort) == ["networkTests", "networkUITests"]
        and all(
          .TestConfigurations[0].TestTargets[];
          (.EnvironmentVariables | type) == "object"
          and (.CommandLineArguments | type) == "array"
          and .CommandLineArguments == []
          and ([
            .EnvironmentVariables
            | keys[]
            | select(startswith("UR_") or startswith("URNETWORK_"))
          ] | length) == 0
          and (has("OnlyTestIdentifiers") | not)
          and (has("SkipTestIdentifiers") | not)
        )
      ) then
        .TestConfigurations[0].TestTargets |= map(
          if .BlueprintName == "networkTests" then
            .EnvironmentVariables.UR_HARDWARE_UI_NO_VPN = "1"
            | .EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE = $nonce
            | .CommandLineArguments = [
                "--urnetwork-hardware-startup-no-vpn"
              ]
            | .ParallelizationEnabled = false
          elif .BlueprintName == "networkUITests" then
            .EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE = $nonce
            | .EnvironmentVariables.UR_HARDWARE_UI_DEVICE_ID = $device_id
            | .ParallelizationEnabled = false
          else
            error("unexpected xctestrun test target")
          end
        )
      else
        error("xctestrun does not contain the exact enabled hardware allowlist")
      end
    ' "$source_json" >"$output_json"; then
    rm -f -- "$source_json" "$output_json"
    return 1
  fi

  if ! /usr/bin/plutil -convert xml1 -o "$output" "$output_json"; then
    rm -f -- "$source_json" "$output_json" "$output"
    return 1
  fi
  rm -f -- "$source_json" "$output_json"
  chmod 600 "$output"
  apple_hardware_xctestrun_has_paired_no_vpn_contract \
    "$output" "$nonce" "$device_id"
}

apple_hardware_xctestrun_has_paired_no_vpn_contract() {
  local xctestrun="$1" nonce="$2" device_id="$3"
  case "$nonce" in
    ????????-*) return 2 ;;
    ''|*[!0-9a-f]*) return 2 ;;
  esac
  [ "${#nonce}" -eq 32 ] || return 2
  case "$device_id" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac

  /usr/bin/plutil -convert json -o - "$xctestrun" 2>/dev/null | \
    jq -e --arg nonce "$nonce" --arg device_id "$device_id" '
      def target($name):
        .TestConfigurations[0].TestTargets[]
        | select(.BlueprintName == $name);

      .["__xctestrun_metadata__"].FormatVersion == 2
      and (.TestConfigurations | type) == "array"
      and (.TestConfigurations | length) == 1
      and .TestConfigurations[0].IsEnabled == true
      and (.TestConfigurations[0].TestTargets | type) == "array"
      and ([
        .TestConfigurations[0].TestTargets[].BlueprintName
      ] | sort) == ["networkTests", "networkUITests"]
      and (target("networkTests") |
        .IsAppHostedTestBundle == true
        and .TestHostBundleIdentifier == "network.ur"
        and (.EnvironmentVariables | type) == "object"
        and .EnvironmentVariables.UR_HARDWARE_UI_NO_VPN == "1"
        and .EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE == $nonce
        and ([
          .EnvironmentVariables
          | keys[]
          | select(startswith("UR_") or startswith("URNETWORK_"))
        ] | sort) == [
          "UR_HARDWARE_UI_NO_VPN",
          "UR_HARDWARE_UI_TEST_NONCE"
        ]
        and .CommandLineArguments
          == ["--urnetwork-hardware-startup-no-vpn"]
        and .ParallelizationEnabled == false
        and (has("OnlyTestIdentifiers") | not)
        and (has("SkipTestIdentifiers") | not)
      )
      and (target("networkUITests") |
        .IsUITestBundle == true
        and .TestHostBundleIdentifier
          == "network.ur.networkUITests.xctrunner"
        and (.EnvironmentVariables | type) == "object"
        and .EnvironmentVariables.UR_HARDWARE_UI_TEST_NONCE == $nonce
        and .EnvironmentVariables.UR_HARDWARE_UI_DEVICE_ID == $device_id
        and ([
          .EnvironmentVariables
          | keys[]
          | select(startswith("UR_") or startswith("URNETWORK_"))
        ] | sort) == [
          "UR_HARDWARE_UI_DEVICE_ID",
          "UR_HARDWARE_UI_TEST_NONCE"
        ]
        and .CommandLineArguments == []
        and .ParallelizationEnabled == false
        and (has("OnlyTestIdentifiers") | not)
        and (has("SkipTestIdentifiers") | not)
      )
    ' >/dev/null
}

apple_hardware_verify_unit_log() {
  local log="$1"
  ! grep -qE 'Test skipped|Testing failed:|\*\* TEST FAILED \*\*' "$log" || return 1
  grep -Eq 'Test run with [1-9][0-9]* tests.*passed' "$log"
}

apple_hardware_verify_test_log() {
  local log="$1" device_id="$2" count
  case "$device_id" in
    ''|*[!A-Za-z0-9-]*) return 2 ;;
  esac
  ! grep -qE 'Test skipped|\*\* TEST FAILED \*\*' "$log" || return 1
  count="$(grep -cF "UR_HARDWARE_STARTUP_PASS device=$device_id" "$log" || true)"
  [ "$count" -eq 1 ]
}

apple_hardware_find_unguarded_profile_calls() {
  local source_root="$1" gateway="$2" match

  while IFS= read -r match; do
    [ -n "$match" ] || continue
    case "$match" in
      "$gateway":*) continue ;;
    esac
    if printf '%s\n' "$match" | grep -Eq \
      '^[^:]+:[0-9]+:[[:space:]]*//'; then
      continue
    fi
    if printf '%s\n' "$match" | grep -Eq \
      'VPNProfileSystem[[:space:]]*\.[[:space:]]*(loadAllFromPreferences|saveToPreferences|loadFromPreferences|removeFromPreferences|startVPNTunnel|stopVPNTunnel)([^A-Za-z0-9_]|$)'; then
      continue
    fi
    printf '%s\n' "$match"
  done < <(
    rg --pcre2 -n --no-heading \
      'NEVPNManager|NETunnelProviderManager\s*\(|NETunnelProviderManager\s*\.\s*loadAllFromPreferences\b|(?<!["A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_]*|\))\s*\.\s*(?:saveToPreferences|loadFromPreferences|removeFromPreferences|startVPNTunnel|stopVPNTunnel)\b' \
      "$source_root" --glob '*.swift' || true
  )
}

apple_hardware_source_contract() {
  local apple_root="$1" dangerous_matches
  local physical_contract_line physical_unit_line
  local simulator_contract_line simulator_unit_line
  local gateway="$apple_root/app/network/Shared/VPNProfileSystem.swift"
  local runner="$apple_root/test-hardware-startup.sh"

  dangerous_matches="$(
    apple_hardware_find_unguarded_profile_calls \
      "$apple_root/app/network" "$gateway"
  )"
  [ -z "$dangerous_matches" ] || {
    printf '%s\n' "$dangerous_matches" >&2
    return 1
  }

  grep -Fq '#if DEBUG && URNETWORK_HARDWARE_UI_TESTING && os(iOS)' \
    "$apple_root/app/network/Shared/AppStartupMode.swift" || return 1
  grep -Fq 'testSupportCompiled: false' \
    "$apple_root/app/networkTests/AppStartupModeTests.swift" || return 1
  grep -Fq -- \
    '-only-testing:networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess' \
    "$runner" || return 1
  [ "$(grep -cF -- '-only-testing:networkTests' "$runner")" -eq 2 ] || \
    return 1
  [ "$(grep -cF -- '-only-testing:networkUITests/HardwareStartupNoVPNUITests/testDeviceStartsWithoutVPNProfileAccess' "$runner")" -eq 2 ] || \
    return 1
  [ "$(grep -c -- '-only-testing:' "$runner")" -eq 4 ] || return 1
  [ "$(grep -c -- '^[[:space:]]*-jobs 1' "$runner")" -eq 6 ] || return 1
  [ "$(grep -c -- '-parallel-testing-enabled NO' "$runner")" -eq 4 ] || \
    return 1
  ! grep -Eq -- \
    '-only-testing:.*(testMainAcceptance|testColdProcessRelaunch|Egress|Peer|Tunnel)' \
    "$runner" || return 1

  local ui_test="$apple_root/app/networkUITests/HardwareStartupNoVPNUITests.swift"
  grep -Fq 'application.descendants(matching: .any)' "$ui_test" || return 1
  ! grep -Eq \
    'app\.staticTexts\["hardware\.startup\.' "$ui_test" || return 1

  physical_contract_line="$(
    grep -n 'apple_hardware_xctestrun_has_paired_no_vpn_contract' "$runner" |
      sed -n '2s/:.*//p'
  )"
  simulator_contract_line="$(
    grep -n 'apple_hardware_xctestrun_has_paired_no_vpn_contract' "$runner" |
      sed -n '5s/:.*//p'
  )"
  physical_unit_line="$(grep -n -- '-only-testing:networkTests' "$runner" |
    sed -n '1s/:.*//p')"
  simulator_unit_line="$(grep -n -- '-only-testing:networkTests' "$runner" |
    sed -n '2s/:.*//p')"
  [ -n "$physical_contract_line" ] && [ -n "$physical_unit_line" ] && \
    [ -n "$simulator_contract_line" ] && [ -n "$simulator_unit_line" ] || \
    return 1
  [ "$physical_contract_line" -lt "$physical_unit_line" ] && \
    [ "$simulator_contract_line" -lt "$simulator_unit_line" ]
}
