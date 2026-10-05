package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The macOS direct-download build (targets URnetworkDirect,
// URnetworkVPNSystem and URnetworkSplitTunnelDirect) is a separate product
// family from the App Store build: com.bringyour.urnetwork /
// com.bringyour.urnetwork.extension / com.bringyour.urnetwork.splittunnel
// with their own app group, keychain group and mach services, so the two can
// be installed side by side and provisioned as separate App IDs. These
// identifiers are spelled in places that cannot share a constant (the
// pbxproj, the entitlements files, the sysext Info.plists and the Swift
// TunnelProviderIdentity); this test keeps them agreeing, and keeps the App
// Store targets on network.ur.

const (
	directTeam        = "6BGU69Q742"
	directApp         = "com.bringyour.urnetwork"
	directTunnel      = "com.bringyour.urnetwork.extension"
	directGroup       = directTeam + ".group." + directApp
	directMachService = directTeam + ".group." + directApp + ".extension"
	directKeychain    = "$(AppIdentifierPrefix)" + directApp + ".tunnel-credentials"

	// the macOS per-app split tunnel: a transparent proxy system extension
	// in each family (splittunnel/)
	directSplitTunnel            = "com.bringyour.urnetwork.splittunnel"
	directSplitTunnelMachService = directTeam + ".group." + directApp + ".splittunnel"

	storeApp                    = "network.ur"
	storeTunnel                 = "network.ur.extension"
	storeSplitTunnel            = "network.ur.splittunnel"
	storeGroup                  = directTeam + ".group." + storeApp
	storeSplitTunnelMachService = directTeam + ".group." + storeApp + ".splittunnel"

	// The account's Developer ID provisioning profiles: the only profiles
	// that carry packet-tunnel-provider-systemextension (Xcode's automatic
	// "Mac Team Provisioning Profile"s never do), so the direct targets
	// are signed manually with them.
	directAppProfile    = "URnetwork Download"
	directTunnelProfile = "URnetwork Extension Download"
	// created in the portal for the split tunnel extension (see
	// app/splittunnel/splittunnel-direct.entitlements)
	directSplitTunnelProfile = "URnetwork Split Tunnel Download"
	developerIdIdentity      = "Developer ID Application"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the repo root")
	}
	return filepath.Dir(source)
}

// Parse any plist (entitlements included) with the system plutil.
func plistJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", path).CombinedOutput()
	if err != nil {
		t.Fatalf("%s is not a well-formed plist: %v\n%s", path, err, out)
	}
	object := map[string]any{}
	if err := json.Unmarshal(out, &object); err != nil {
		t.Fatalf("%s did not convert to a JSON object: %v\n%s", path, err, out)
	}
	return object
}

func stringList(value any) []string {
	items, _ := value.([]any)
	list := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok {
			list = append(list, s)
		}
	}
	return list
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

// The build settings of one XCBuildConfiguration block of project.pbxproj,
// found by the block's comment ("/* Debug */" after the id) inside the
// configuration list of the named target.
func targetBuildSettings(t *testing.T, target, configuration string) map[string]string {
	t.Helper()
	pbx, err := os.ReadFile(filepath.Join(repoRoot(t), "app", "app.xcodeproj", "project.pbxproj"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(pbx)
	listRe := regexp.MustCompile(`(?s)/\* Build configuration list for PBXNativeTarget "` + regexp.QuoteMeta(target) + `" \*/ = \{.*?buildConfigurations = \((.*?)\);`)
	list := listRe.FindStringSubmatch(text)
	if list == nil {
		t.Fatalf("target %s has no configuration list", target)
	}
	idRe := regexp.MustCompile(`([0-9A-F]{24}) /\* ` + regexp.QuoteMeta(configuration) + ` \*/`)
	id := idRe.FindStringSubmatch(list[1])
	if id == nil {
		t.Fatalf("target %s has no %s configuration", target, configuration)
	}
	blockRe := regexp.MustCompile(`(?s)\t\t` + id[1] + ` /\* ` + regexp.QuoteMeta(configuration) + ` \*/ = \{.*?buildSettings = \{\n(.*?)\n\t\t\t\};`)
	block := blockRe.FindStringSubmatch(text)
	if block == nil {
		t.Fatalf("configuration %s of %s has no buildSettings", id[1], target)
	}
	settings := map[string]string{}
	for _, line := range strings.Split(block[1], "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), " = ")
		if !ok {
			continue
		}
		settings[strings.Trim(key, `"`)] = strings.Trim(strings.TrimSuffix(value, ";"), `"`)
	}
	return settings
}

func TestDirectTargetsUseTheBringYourBundleIds(t *testing.T) {
	for _, configuration := range []string{"Debug", "Release"} {
		app := targetBuildSettings(t, "URnetworkDirect", configuration)
		if app["PRODUCT_BUNDLE_IDENTIFIER"] != directApp {
			t.Fatalf("URnetworkDirect %s PRODUCT_BUNDLE_IDENTIFIER = %q, want %q", configuration, app["PRODUCT_BUNDLE_IDENTIFIER"], directApp)
		}
		if app["UR_TUNNEL_PROVIDER_BUNDLE_ID"] != directTunnel {
			t.Fatalf("URnetworkDirect %s UR_TUNNEL_PROVIDER_BUNDLE_ID = %q, want %q", configuration, app["UR_TUNNEL_PROVIDER_BUNDLE_ID"], directTunnel)
		}
		for _, key := range []string{"UR_SHARED_KEYCHAIN_ACCESS_GROUP", "INFOPLIST_KEY_URSharedKeychainAccessGroup"} {
			if app[key] != directKeychain {
				t.Fatalf("URnetworkDirect %s %s = %q, want %q", configuration, key, app[key], directKeychain)
			}
		}
		// the App Store OAuth client is tied to network.ur; the direct build
		// takes its own client id from DIRECT_GOOGLE_CLIENT_ID, empty until
		// one exists
		if app["UR_GOOGLE_CLIENT_ID"] != "$(DIRECT_GOOGLE_CLIENT_ID)" || app["UR_GOOGLE_URL_SCHEME"] != "$(DIRECT_GOOGLE_URL_SCHEME)" {
			t.Fatalf("URnetworkDirect %s must take its Google client from DIRECT_GOOGLE_CLIENT_ID / DIRECT_GOOGLE_URL_SCHEME: %q %q", configuration, app["UR_GOOGLE_CLIENT_ID"], app["UR_GOOGLE_URL_SCHEME"])
		}
		if !strings.Contains(app["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DIRECT_DOWNLOAD") {
			t.Fatalf("URnetworkDirect %s does not define DIRECT_DOWNLOAD", configuration)
		}
		if app["CODE_SIGN_ENTITLEMENTS"] != "network/network-macOS-direct.entitlements" {
			t.Fatalf("URnetworkDirect %s entitlements = %q", configuration, app["CODE_SIGN_ENTITLEMENTS"])
		}

		ext := targetBuildSettings(t, "URnetworkVPNSystem", configuration)
		if ext["PRODUCT_BUNDLE_IDENTIFIER"] != directTunnel {
			t.Fatalf("URnetworkVPNSystem %s PRODUCT_BUNDLE_IDENTIFIER = %q, want %q", configuration, ext["PRODUCT_BUNDLE_IDENTIFIER"], directTunnel)
		}
		if ext["INFOPLIST_FILE"] != "extension/Info-macOS-sysext.plist" || ext["CODE_SIGN_ENTITLEMENTS"] != "extension/extension-macOS-sysext.entitlements" {
			t.Fatalf("URnetworkVPNSystem %s plist/entitlements = %q / %q", configuration, ext["INFOPLIST_FILE"], ext["CODE_SIGN_ENTITLEMENTS"])
		}

		splitTunnelBuildSettingValues := targetBuildSettings(t, "URnetworkSplitTunnelDirect", configuration)
		if splitTunnelBuildSettingValues["PRODUCT_BUNDLE_IDENTIFIER"] != directSplitTunnel {
			t.Fatalf("URnetworkSplitTunnelDirect %s PRODUCT_BUNDLE_IDENTIFIER = %q, want %q", configuration, splitTunnelBuildSettingValues["PRODUCT_BUNDLE_IDENTIFIER"], directSplitTunnel)
		}
		if splitTunnelBuildSettingValues["INFOPLIST_FILE"] != "splittunnel/Info-direct.plist" || splitTunnelBuildSettingValues["CODE_SIGN_ENTITLEMENTS"] != "splittunnel/splittunnel-direct.entitlements" {
			t.Fatalf("URnetworkSplitTunnelDirect %s plist/entitlements = %q / %q", configuration, splitTunnelBuildSettingValues["INFOPLIST_FILE"], splitTunnelBuildSettingValues["CODE_SIGN_ENTITLEMENTS"])
		}
		if !strings.Contains(splitTunnelBuildSettingValues["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DIRECT_DOWNLOAD") {
			t.Fatalf("URnetworkSplitTunnelDirect %s does not define DIRECT_DOWNLOAD", configuration)
		}
	}
}

// The split tunnel extensions are macOS-only system extensions on the macOS
// 15 flow API; each app family embeds its own, and the App Store app (which
// also builds for iOS) embeds it for macOS only.
func TestSplitTunnelTargets(t *testing.T) {
	for _, configuration := range []string{"Debug", "Release"} {
		for target, want := range map[string][3]string{
			"URnetworkSplitTunnel":       {storeSplitTunnel, "splittunnel/Info.plist", "splittunnel/splittunnel.entitlements"},
			"URnetworkSplitTunnelDirect": {directSplitTunnel, "splittunnel/Info-direct.plist", "splittunnel/splittunnel-direct.entitlements"},
		} {
			buildSettingValues := targetBuildSettings(t, target, configuration)
			if buildSettingValues["PRODUCT_BUNDLE_IDENTIFIER"] != want[0] || buildSettingValues["INFOPLIST_FILE"] != want[1] || buildSettingValues["CODE_SIGN_ENTITLEMENTS"] != want[2] {
				t.Fatalf("%s %s = %q / %q / %q, want %v", target, configuration, buildSettingValues["PRODUCT_BUNDLE_IDENTIFIER"], buildSettingValues["INFOPLIST_FILE"], buildSettingValues["CODE_SIGN_ENTITLEMENTS"], want)
			}
			if buildSettingValues["SDKROOT"] != "macosx" || buildSettingValues["SUPPORTED_PLATFORMS"] != "macosx" || buildSettingValues["MACOSX_DEPLOYMENT_TARGET"] != "15.0" {
				t.Fatalf("%s %s is not a macOS 15 target: %q %q %q", target, configuration, buildSettingValues["SDKROOT"], buildSettingValues["SUPPORTED_PLATFORMS"], buildSettingValues["MACOSX_DEPLOYMENT_TARGET"])
			}
			if buildSettingValues["ENABLE_APP_SANDBOX"] != "YES" || buildSettingValues["ENABLE_HARDENED_RUNTIME"] != "YES" {
				t.Fatalf("%s %s sandbox/hardened runtime = %q / %q", target, configuration, buildSettingValues["ENABLE_APP_SANDBOX"], buildSettingValues["ENABLE_HARDENED_RUNTIME"])
			}
			// the release pipeline stamps every MARKETING_VERSION and
			// CURRENT_PROJECT_VERSION in the pbxproj; a system extension
			// whose version never changes is never replaced by an update
			if buildSettingValues["MARKETING_VERSION"] == "" || buildSettingValues["CURRENT_PROJECT_VERSION"] == "" {
				t.Fatalf("%s %s carries no version settings for the pipeline to stamp", target, configuration)
			}
		}
	}

	pbxprojBytes, err := os.ReadFile(filepath.Join(repoRoot(t), "app", "app.xcodeproj", "project.pbxproj"))
	if err != nil {
		t.Fatal(err)
	}
	pbxprojText := string(pbxprojBytes)
	for _, want := range []string{
		// the App Store app embeds its extension for macOS only; without the
		// filters the iOS build refuses a macOS binary inside the app
		`/* URnetworkSplitTunnel.systemextension in Embed System Extensions */ = {isa = PBXBuildFile; fileRef = C5A100212F0E000100000021 /* URnetworkSplitTunnel.systemextension */; platformFilters = (macos, );`,
		"isa = PBXTargetDependency;\n\t\t\tplatformFilters = (\n\t\t\t\tmacos,\n\t\t\t);\n\t\t\ttarget = C5A100412F0E000100000041 /* URnetworkSplitTunnel */;",
		// the direct app embeds its own next to the packet tunnel
		"A1D000112F0D000100000011 /* URnetworkVPNSystem.systemextension in Embed System Extensions */,\n\t\t\t\tC5A100022F0E000100000002 /* URnetworkSplitTunnelDirect.systemextension in Embed System Extensions */,",
	} {
		if !strings.Contains(pbxprojText, want) {
			t.Fatalf("project.pbxproj lacks %q", want)
		}
	}
}

// Both configurations of the three direct targets sign manually with the
// Developer ID identity and the matching Developer ID profile: Debug too,
// because the automatic profile fails the same entitlement check whatever
// the configuration (an unsigned CODE_SIGNING_ALLOWED=NO build is unaffected
// by the signing style). The names must agree with
// ExportOptions-DeveloperID.plist, which re-signs the export with them.
func TestDirectTargetsSignManuallyWithDeveloperID(t *testing.T) {
	export := plistJSON(t, filepath.Join(repoRoot(t), "app", "ExportOptions-DeveloperID.plist"))
	profiles, _ := export["provisioningProfiles"].(map[string]any)
	for _, configuration := range []string{"Debug", "Release"} {
		for target, want := range map[string][2]string{
			"URnetworkDirect":            {directApp, directAppProfile},
			"URnetworkVPNSystem":         {directTunnel, directTunnelProfile},
			"URnetworkSplitTunnelDirect": {directSplitTunnel, directSplitTunnelProfile},
		} {
			settings := targetBuildSettings(t, target, configuration)
			if settings["CODE_SIGN_STYLE"] != "Manual" {
				t.Fatalf("%s %s CODE_SIGN_STYLE = %q, want Manual", target, configuration, settings["CODE_SIGN_STYLE"])
			}
			if settings["CODE_SIGN_IDENTITY"] != developerIdIdentity {
				t.Fatalf("%s %s CODE_SIGN_IDENTITY = %q, want %q", target, configuration, settings["CODE_SIGN_IDENTITY"], developerIdIdentity)
			}
			if settings["DEVELOPMENT_TEAM"] != directTeam {
				t.Fatalf("%s %s DEVELOPMENT_TEAM = %q, want %q", target, configuration, settings["DEVELOPMENT_TEAM"], directTeam)
			}
			if settings["PROVISIONING_PROFILE_SPECIFIER"] != want[1] {
				t.Fatalf("%s %s PROVISIONING_PROFILE_SPECIFIER = %q, want %q", target, configuration, settings["PROVISIONING_PROFILE_SPECIFIER"], want[1])
			}
			if settings["ENABLE_HARDENED_RUNTIME"] != "YES" {
				t.Fatalf("%s %s ENABLE_HARDENED_RUNTIME = %q; notarization requires it", target, configuration, settings["ENABLE_HARDENED_RUNTIME"])
			}
			if profiles[want[0]] != want[1] {
				t.Fatalf("ExportOptions-DeveloperID.plist provisioningProfiles[%s] = %v, but %s signs with %q", want[0], profiles[want[0]], target, want[1])
			}
		}
	}
	// the App Store targets keep automatic signing
	for _, configuration := range []string{"Debug", "Release"} {
		for _, target := range []string{"URnetwork", "URnetworkVPN", "URnetworkSplitTunnel"} {
			settings := targetBuildSettings(t, target, configuration)
			if settings["CODE_SIGN_STYLE"] != "Automatic" || settings["PROVISIONING_PROFILE_SPECIFIER"] != "" || settings["CODE_SIGN_IDENTITY"] != "Apple Development" {
				t.Fatalf("%s %s is no longer automatically signed: style %q identity %q profile %q", target, configuration, settings["CODE_SIGN_STYLE"], settings["CODE_SIGN_IDENTITY"], settings["PROVISIONING_PROFILE_SPECIFIER"])
			}
		}
	}
}

func TestAppStoreTargetsKeepTheirBundleIds(t *testing.T) {
	for _, configuration := range []string{"Debug", "Release"} {
		app := targetBuildSettings(t, "URnetwork", configuration)
		if app["PRODUCT_BUNDLE_IDENTIFIER"] != storeApp || app["UR_TUNNEL_PROVIDER_BUNDLE_ID"] != storeTunnel {
			t.Fatalf("URnetwork %s = %q / %q", configuration, app["PRODUCT_BUNDLE_IDENTIFIER"], app["UR_TUNNEL_PROVIDER_BUNDLE_ID"])
		}
		if app["UR_SHARED_KEYCHAIN_ACCESS_GROUP"] != "$(AppIdentifierPrefix)network.ur.tunnel-credentials" {
			t.Fatalf("URnetwork %s keychain group = %q", configuration, app["UR_SHARED_KEYCHAIN_ACCESS_GROUP"])
		}
		if !strings.HasSuffix(app["UR_GOOGLE_CLIENT_ID"], ".apps.googleusercontent.com") || !strings.HasPrefix(app["UR_GOOGLE_URL_SCHEME"], "com.googleusercontent.apps.") {
			t.Fatalf("URnetwork %s lost its Google client: %q %q", configuration, app["UR_GOOGLE_CLIENT_ID"], app["UR_GOOGLE_URL_SCHEME"])
		}
		if strings.Contains(app["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DIRECT_DOWNLOAD") {
			t.Fatalf("URnetwork %s defines DIRECT_DOWNLOAD", configuration)
		}
		ext := targetBuildSettings(t, "URnetworkVPN", configuration)
		if ext["PRODUCT_BUNDLE_IDENTIFIER"] != storeTunnel {
			t.Fatalf("URnetworkVPN %s PRODUCT_BUNDLE_IDENTIFIER = %q", configuration, ext["PRODUCT_BUNDLE_IDENTIFIER"])
		}
	}
}

func TestDirectEntitlementsAndSysextPlistAgree(t *testing.T) {
	root := repoRoot(t)

	app := plistJSON(t, filepath.Join(root, "app", "network", "network-macOS-direct.entitlements"))
	groups := stringList(app["com.apple.security.application-groups"])
	if len(groups) != 1 || groups[0] != directGroup {
		t.Fatalf("direct app application-groups = %v, want [%s]", groups, directGroup)
	}
	keychain := stringList(app["keychain-access-groups"])
	if len(keychain) != 1 || keychain[0] != directKeychain {
		t.Fatalf("direct app keychain-access-groups = %v, want [%s]", keychain, directKeychain)
	}
	ne := stringList(app["com.apple.developer.networking.networkextension"])
	if !contains(ne, "packet-tunnel-provider-systemextension") || !contains(ne, "dns-settings") || contains(ne, "packet-tunnel-provider") {
		t.Fatalf("direct app networkextension = %v", ne)
	}
	// the split tunnel's NETransparentProxyManager; "URnetwork Download"
	// grants it
	if !contains(ne, "app-proxy-provider-systemextension") || contains(ne, "app-proxy-provider") {
		t.Fatalf("direct app networkextension = %v, want app-proxy-provider-systemextension", ne)
	}
	if app["com.apple.developer.system-extension.install"] != true {
		t.Fatal("direct app lacks com.apple.developer.system-extension.install")
	}
	if _, present := app["aps-environment"]; present {
		t.Fatal("direct app carries aps-environment; push is not used on macOS")
	}
	if _, present := app["com.apple.developer.aps-environment"]; present {
		t.Fatal("direct app carries com.apple.developer.aps-environment")
	}
	// Everything the direct app asks for must be granted by the Developer
	// ID profile "URnetwork Download". It does not carry applesignin (the
	// native Apple button is hidden in this build, see
	// AppleSignInConfiguration) nor networking.vpn.api (the personal-VPN
	// NEVPNManager entitlement; the app only uses NETunnelProviderManager).
	for _, key := range []string{"com.apple.developer.applesignin", "com.apple.developer.networking.vpn.api"} {
		if _, present := app[key]; present {
			t.Fatalf("direct app carries %s, which the Developer ID profile does not grant", key)
		}
	}
	for key := range app {
		switch key {
		case "com.apple.security.application-groups",
			"com.apple.developer.networking.networkextension",
			"com.apple.developer.system-extension.install",
			"keychain-access-groups":
		case "com.apple.security.files.bookmarks.app-scope":
			// an App Sandbox entitlement (the in-app updater's persisted
			// Applications-folder bookmark, test-direct-updater_test.go),
			// enforced by the sandbox and never granted by a profile
		default:
			t.Fatalf("direct app carries %s, which is not in the Developer ID profile", key)
		}
	}

	ext := plistJSON(t, filepath.Join(root, "app", "extension", "extension-macOS-sysext.entitlements"))
	groups = stringList(ext["com.apple.security.application-groups"])
	if len(groups) != 1 || groups[0] != directGroup {
		t.Fatalf("sysext application-groups = %v, want [%s]", groups, directGroup)
	}
	if _, present := ext["keychain-access-groups"]; present {
		t.Fatal("the system extension must not carry keychain-access-groups (root boundary)")
	}
	ne = stringList(ext["com.apple.developer.networking.networkextension"])
	if len(ne) != 1 || ne[0] != "packet-tunnel-provider-systemextension" {
		t.Fatalf("sysext networkextension = %v", ne)
	}

	info := plistJSON(t, filepath.Join(root, "app", "extension", "Info-macOS-sysext.plist"))
	network, _ := info["NetworkExtension"].(map[string]any)
	if network["NEMachServiceName"] != directMachService {
		t.Fatalf("NEMachServiceName = %v, want %s", network["NEMachServiceName"], directMachService)
	}
	// the mach service must be prefixed by one of the extension's app groups
	if !strings.HasPrefix(directMachService, directGroup+".") {
		t.Fatalf("NEMachServiceName %s is not prefixed by the app group %s", directMachService, directGroup)
	}
	classes, _ := network["NEProviderClasses"].(map[string]any)
	if classes["com.apple.networkextension.packet-tunnel"] != "$(PRODUCT_MODULE_NAME).PacketTunnelProvider" {
		t.Fatalf("NEProviderClasses = %v", classes)
	}
	if _, present := info["URSharedKeychainAccessGroup"]; present {
		t.Fatal("the system extension Info.plist names a keychain access group")
	}

	// the split tunnel extensions, one per family
	for _, family := range []struct {
		entitlements, info, group, machService, provider string
	}{
		{
			entitlements: "splittunnel-direct.entitlements",
			info:         "Info-direct.plist",
			group:        directGroup,
			machService:  directSplitTunnelMachService,
			provider:     "app-proxy-provider-systemextension",
		},
		{
			entitlements: "splittunnel.entitlements",
			info:         "Info.plist",
			group:        storeGroup,
			machService:  storeSplitTunnelMachService,
			provider:     "app-proxy-provider",
		},
	} {
		entitlementValues := plistJSON(t, filepath.Join(root, "app", "splittunnel", family.entitlements))
		if appGroups := stringList(entitlementValues["com.apple.security.application-groups"]); len(appGroups) != 1 || appGroups[0] != family.group {
			t.Fatalf("%s application-groups = %v, want [%s]", family.entitlements, appGroups, family.group)
		}
		if _, present := entitlementValues["keychain-access-groups"]; present {
			t.Fatalf("%s carries keychain-access-groups (root boundary)", family.entitlements)
		}
		if networkExtensionTypes := stringList(entitlementValues["com.apple.developer.networking.networkextension"]); len(networkExtensionTypes) != 1 || networkExtensionTypes[0] != family.provider {
			t.Fatalf("%s networkextension = %v, want [%s]", family.entitlements, networkExtensionTypes, family.provider)
		}
		for key := range entitlementValues {
			switch key {
			case "com.apple.security.application-groups", "com.apple.developer.networking.networkextension":
			default:
				t.Fatalf("%s carries %s, which its profile may not grant", family.entitlements, key)
			}
		}
		infoValues := plistJSON(t, filepath.Join(root, "app", "splittunnel", family.info))
		networkExtensionValues, _ := infoValues["NetworkExtension"].(map[string]any)
		if networkExtensionValues["NEMachServiceName"] != family.machService || !strings.HasPrefix(family.machService, family.group+".") {
			t.Fatalf("%s NEMachServiceName = %v, want %s (prefixed by %s)", family.info, networkExtensionValues["NEMachServiceName"], family.machService, family.group)
		}
		providerTypeClasses, _ := networkExtensionValues["NEProviderClasses"].(map[string]any)
		if len(providerTypeClasses) != 1 || providerTypeClasses["com.apple.networkextension.app-proxy"] != "$(PRODUCT_MODULE_NAME).SplitTunnelProxyProvider" {
			t.Fatalf("%s NEProviderClasses = %v", family.info, providerTypeClasses)
		}
	}

	// the App Store app may now install a system extension and configure a
	// transparent proxy; its profiles grant both
	storeEntitlementValues := plistJSON(t, filepath.Join(root, "app", "network", "network-macOS.entitlements"))
	if storeEntitlementValues["com.apple.developer.system-extension.install"] != true || !contains(stringList(storeEntitlementValues["com.apple.developer.networking.networkextension"]), "app-proxy-provider") {
		t.Fatalf("App Store macOS app entitlements lack system-extension.install or app-proxy-provider: %v", storeEntitlementValues)
	}
}

// The Swift constant and DiagnosticsLogContract are the runtime side of the
// same identifiers; they cannot be imported here, so the source is checked.
func TestSwiftIdentityConstantsMatch(t *testing.T) {
	root := repoRoot(t)
	identity, err := os.ReadFile(filepath.Join(root, "app", "network", "Shared", "TunnelProviderIdentity.swift"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`appBundleIdentifier: "` + directApp + `"`,
		`tunnelBundleIdentifier: "` + directTunnel + `"`,
		`appGroupBase: "group.` + directApp + `"`,
		`keychainAccessGroupSuffix: "` + directApp + `.tunnel-credentials"`,
		`splitTunnelBundleIdentifier: "` + directSplitTunnel + `"`,
		`appBundleIdentifier: "` + storeApp + `"`,
		`tunnelBundleIdentifier: "` + storeTunnel + `"`,
		`splitTunnelBundleIdentifier: "` + storeSplitTunnel + `"`,
	} {
		if !strings.Contains(string(identity), want) {
			t.Fatalf("TunnelProviderIdentity.swift lacks %s", want)
		}
	}
	contract, err := os.ReadFile(filepath.Join(root, "app", "network", "Shared", "DiagnosticsLogContract.swift"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contract), `"group.`+directApp+`"`) || !strings.Contains(string(contract), `"group.`+storeApp+`"`) {
		t.Fatal("DiagnosticsLogContract.appGroupIdentifierBase does not carry both app groups")
	}
	// no app code may name the provider id directly any more
	for _, file := range []string{
		"network/Shared/ViewModels/VPNManager.swift",
		"network/Shared/SystemExtension/SystemExtensionActivator.swift",
		"network/Main/Account/Widgets/WidgetPreviewModel.swift",
	} {
		source, err := os.ReadFile(filepath.Join(root, "app", file))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(source), `"`+storeTunnel+`"`) {
			t.Fatalf("%s still hardcodes %q; use TunnelProviderIdentity.bundleIdentifier", file, storeTunnel)
		}
	}
}

// The shared URnetwork-Info.plist must take every per-target value from a
// build setting, so the two app targets can produce different plists.
func TestSharedInfoPlistUsesBuildSettings(t *testing.T) {
	info, err := os.ReadFile(filepath.Join(repoRoot(t), "app", "URnetwork-Info.plist"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(info)
	for _, want := range []string{
		"$(UR_SHARED_KEYCHAIN_ACCESS_GROUP)",
		"$(UR_TUNNEL_PROVIDER_BUNDLE_ID)",
		"$(UR_GOOGLE_CLIENT_ID)",
		"$(UR_GOOGLE_URL_SCHEME)",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("URnetwork-Info.plist does not use %s", want)
		}
	}
	for _, literal := range []string{storeTunnel + "</string>", "apps.googleusercontent.com</string>", "com.googleusercontent.apps."} {
		if strings.Contains(text, literal) {
			t.Fatalf("URnetwork-Info.plist still hardcodes %s", literal)
		}
	}
}

// With UR_DIRECT_APP pointing at a built URnetwork.app of the URnetworkDirect
// scheme, the product itself is checked (skipped otherwise; the unsigned
// macOS build in build.sh-style runs sets it).
func TestBuiltDirectProduct(t *testing.T) {
	app := os.Getenv("UR_DIRECT_APP")
	if app == "" {
		t.Skip("UR_DIRECT_APP not set")
	}
	info := plistJSON(t, filepath.Join(app, "Contents", "Info.plist"))
	if info["CFBundleIdentifier"] != directApp {
		t.Fatalf("CFBundleIdentifier = %v", info["CFBundleIdentifier"])
	}
	if got := stringList(info["NEVPNConfiguration"]); len(got) != 1 || got[0] != directTunnel {
		t.Fatalf("NEVPNConfiguration = %v", got)
	}
	if info["URSharedKeychainAccessGroup"] != directTeam+"."+directApp+".tunnel-credentials" && info["URSharedKeychainAccessGroup"] != directApp+".tunnel-credentials" {
		t.Fatalf("URSharedKeychainAccessGroup = %v", info["URSharedKeychainAccessGroup"])
	}
	if id, _ := info["GIDClientID"].(string); id != "" && !strings.HasSuffix(id, ".apps.googleusercontent.com") {
		t.Fatalf("GIDClientID = %q", id)
	}
	for _, urlType := range info["CFBundleURLTypes"].([]any) {
		for _, scheme := range stringList(urlType.(map[string]any)["CFBundleURLSchemes"]) {
			if strings.HasPrefix(scheme, "com.googleusercontent.apps.338638865390") {
				t.Fatal("the direct product ships the App Store Google URL scheme")
			}
		}
	}
	if _, err := os.Stat(filepath.Join(app, "Contents", "PlugIns")); err == nil {
		t.Fatal("the direct product embeds app extensions")
	}
	sysext := filepath.Join(app, "Contents", "Library", "SystemExtensions", "URnetworkVPNSystem.systemextension", "Contents", "Info.plist")
	ext := plistJSON(t, sysext)
	if ext["CFBundleIdentifier"] != directTunnel || ext["CFBundlePackageType"] != "SYSX" {
		t.Fatalf("sysext CFBundleIdentifier/CFBundlePackageType = %v / %v", ext["CFBundleIdentifier"], ext["CFBundlePackageType"])
	}
	network, _ := ext["NetworkExtension"].(map[string]any)
	if network["NEMachServiceName"] != directMachService {
		t.Fatalf("built NEMachServiceName = %v", network["NEMachServiceName"])
	}
	splitTunnelInfoValues := plistJSON(t, filepath.Join(app, "Contents", "Library", "SystemExtensions", "URnetworkSplitTunnelDirect.systemextension", "Contents", "Info.plist"))
	if splitTunnelInfoValues["CFBundleIdentifier"] != directSplitTunnel || splitTunnelInfoValues["CFBundlePackageType"] != "SYSX" {
		t.Fatalf("split tunnel sysext CFBundleIdentifier/CFBundlePackageType = %v / %v", splitTunnelInfoValues["CFBundleIdentifier"], splitTunnelInfoValues["CFBundlePackageType"])
	}
	splitTunnelNetworkExtensionValues, _ := splitTunnelInfoValues["NetworkExtension"].(map[string]any)
	if splitTunnelNetworkExtensionValues["NEMachServiceName"] != directSplitTunnelMachService {
		t.Fatalf("built split tunnel NEMachServiceName = %v", splitTunnelNetworkExtensionValues["NEMachServiceName"])
	}
	if _, err := os.Stat(filepath.Join(app, "Contents", "Library", "SystemExtensions", "URnetworkSplitTunnel.systemextension")); err == nil {
		t.Fatal("the direct product embeds the App Store split tunnel extension")
	}

	// A signed product (the Developer ID export) embeds the two profiles;
	// an unsigned build has none and skips this part.
	sysextBundle := filepath.Join(app, "Contents", "Library", "SystemExtensions", "URnetworkVPNSystem.systemextension")
	for _, bundle := range []struct {
		path, profile, appId string
	}{
		{app, directAppProfile, directApp},
		{sysextBundle, directTunnelProfile, directTunnel},
	} {
		embedded := filepath.Join(bundle.path, "Contents", "embedded.provisionprofile")
		if _, err := os.Stat(embedded); err != nil {
			t.Logf("%s: no embedded profile (unsigned build), skipping the profile check", bundle.path)
			continue
		}
		name, entitlements := provisioningProfile(t, embedded)
		if name != bundle.profile {
			t.Fatalf("%s embeds profile %q, want %q", bundle.path, name, bundle.profile)
		}
		if entitlements["com.apple.application-identifier"] != directTeam+"."+bundle.appId {
			t.Fatalf("%s profile com.apple.application-identifier = %v", bundle.path, entitlements["com.apple.application-identifier"])
		}
		if !contains(stringList(entitlements["com.apple.developer.networking.networkextension"]), "packet-tunnel-provider-systemextension") {
			t.Fatalf("%s profile does not grant packet-tunnel-provider-systemextension: %v", bundle.path, entitlements["com.apple.developer.networking.networkextension"])
		}
		signed := signedEntitlements(t, bundle.path)
		if !contains(stringList(signed["com.apple.developer.networking.networkextension"]), "packet-tunnel-provider-systemextension") {
			t.Fatalf("%s is signed without packet-tunnel-provider-systemextension: %v", bundle.path, signed)
		}
		for _, key := range []string{"com.apple.developer.applesignin", "com.apple.developer.networking.vpn.api"} {
			if _, present := signed[key]; present {
				t.Fatalf("%s is signed with %s, which its profile does not grant", bundle.path, key)
			}
		}
	}
}

// Decode a signed provisioning profile with the system security tool: its
// Name and its Entitlements dict (the whole profile carries certificate
// data, which plutil cannot render as JSON).
func provisioningProfile(t *testing.T, path string) (string, map[string]any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/security", "cms", "-D", "-i", path).Output()
	if err != nil {
		t.Fatalf("security cms -D %s: %v", path, err)
	}
	decoded := filepath.Join(t.TempDir(), "profile.plist")
	if err := os.WriteFile(decoded, out, 0o600); err != nil {
		t.Fatal(err)
	}
	name, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "Name", "raw", "-o", "-", decoded).Output()
	if err != nil {
		t.Fatalf("%s has no Name: %v", path, err)
	}
	out, err = exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "Entitlements", "json", "-o", "-", decoded).Output()
	if err != nil {
		t.Fatalf("%s has no Entitlements: %v", path, err)
	}
	entitlements := map[string]any{}
	if err := json.Unmarshal(out, &entitlements); err != nil {
		t.Fatalf("%s Entitlements did not convert to a JSON object: %v\n%s", path, err, out)
	}
	return strings.TrimSpace(string(name)), entitlements
}

// The entitlements a bundle is actually signed with.
func signedEntitlements(t *testing.T, bundle string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", bundle).Output()
	if err != nil {
		t.Fatalf("codesign -d --entitlements %s: %v", bundle, err)
	}
	decoded := filepath.Join(t.TempDir(), "entitlements.plist")
	if err := os.WriteFile(decoded, out, 0o600); err != nil {
		t.Fatal(err)
	}
	return plistJSON(t, decoded)
}
