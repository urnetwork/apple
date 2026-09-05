#!/bin/bash
# Compile the actual version-gated source at the supported minimum OS.
# This does not run the app, install a profile, or contact a device. It is a
# focused compiler regression, not a substitute for the full app build.
set -euo pipefail

source_root=${1:-$(cd "$(dirname "$0")" && pwd)}
ios_minimum=${APPLE_AVAILABILITY_IOS_MINIMUM:-16.0}
macos_minimum=${APPLE_AVAILABILITY_MACOS_MINIMUM:-13.5}
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/urnetwork-apple-availability.XXXXXXXX")
printf 'Availability compiler evidence: %s\n' "$test_directory"

ruby - "$source_root" "$test_directory" <<'RUBY'
root, output = ARGV
vpn_source = File.read(File.join(root, "app/network/Shared/ViewModels/VPNManager.swift"))
vpn_lines = vpn_source.lines
constructors = vpn_lines.each_index.select { |index| vpn_lines[index].strip == "let tunnelProtocol = NETunnelProviderProtocol()" }
abort "Expected exactly one production VPN protocol constructor" unless constructors.length == 1
constructor_lines = vpn_lines[(constructors.first + 1)..]
end_index = constructor_lines.index { |line| line.lstrip.start_with?("guard let rpcSession") }
abort "VPN exclusion block was not found within its constructor" unless end_index && end_index < 64
settings_lines = constructor_lines.take(end_index)
starts = settings_lines.each_index.select { |index| settings_lines[index].strip == "tunnelProtocol.disconnectOnSleep = false" }
abort "Expected exactly one constructor sleep setting" unless starts.length == 1
vpn_block = settings_lines[(starts.first + 1)..].join
%w[excludeLocalNetworks excludeCellularServices excludeAPNs excludeDeviceCommunication].each do |property|
  abort "Missing or duplicated VPN exclusion #{property}" unless vpn_block.scan("tunnelProtocol.#{property} = true").length == 1
end
File.write(File.join(output, "VPNAvailability.swift"), <<~SWIFT)
  import NetworkExtension
  func configurePlatformTrafficExclusions(_ tunnelProtocol: NETunnelProviderProtocol) {
  #{vpn_block}
  }
SWIFT

view_source = File.read(File.join(root, "app/network/iOS/Navigation/MainTabView.swift"))
background_calls = view_source.scan(/^[ \t]*\.(presentationBackground(?:IfAvailable)?)\(themeManager\.currentTheme\.backgroundColor\)[ \t]*$/)
abort "Expected exactly one production introduction background call" unless background_calls.length == 1
File.write(File.join(output, "PresentationAvailability.swift"), <<~SWIFT)
  import SwiftUI
  func introductionPresentationBackground(_ color: Color) -> some View {
      Color.clear.#{background_calls.first.first}(color)
  }
SWIFT
RUBY

failure=0
for platform in iphoneos macosx; do
    sdk_path=$(xcrun --sdk "$platform" --show-sdk-path)
    if [[ "$platform" == iphoneos ]]; then
        target="arm64-apple-ios${ios_minimum}"
    else
        target="arm64-apple-macosx${macos_minimum}"
    fi
    for unit in VPN Presentation; do
        inputs=("$test_directory/${unit}Availability.swift")
        if [[ "$unit" == Presentation ]]; then
            inputs+=("$source_root/app/network/Shared/Extensions/View.swift")
        fi
        printf 'Typechecking %s at %s\n' "$unit" "$target"
        if xcrun --sdk "$platform" swiftc -typecheck -swift-version 5 \
            -sdk "$sdk_path" -target "$target" \
            -module-cache-path "$test_directory/module-cache" \
            "${inputs[@]}"; then
            printf 'PASS %s %s\n' "$unit" "$target"
        else
            compiler_status=$?
            printf 'FAIL %s %s compiler_status=%s\n' "$unit" "$target" "$compiler_status" >&2
            failure=1
        fi
    done
done
exit "$failure"
