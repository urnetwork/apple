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

// The macOS direct-download build (targets URnetworkDirect and
// URnetworkVPNSystem) is a separate product family from the App Store build:
// com.bringyour.urnetwork / com.bringyour.urnetwork.extension with their own
// app group, keychain group and mach service, so the two can be installed
// side by side and provisioned as separate App IDs. These identifiers are
// spelled in five places that cannot share a constant (the pbxproj, two
// entitlements files, the sysext Info.plist and the Swift
// TunnelProviderIdentity); this test keeps them agreeing, and keeps the App
// Store targets on network.ur.

const (
	directTeam        = "6BGU69Q742"
	directApp         = "com.bringyour.urnetwork"
	directTunnel      = "com.bringyour.urnetwork.extension"
	directGroup       = directTeam + ".group." + directApp
	directMachService = directTeam + ".group." + directApp + ".extension"
	directKeychain    = "$(AppIdentifierPrefix)" + directApp + ".tunnel-credentials"

	storeApp    = "network.ur"
	storeTunnel = "network.ur.extension"
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
	if app["com.apple.developer.system-extension.install"] != true {
		t.Fatal("direct app lacks com.apple.developer.system-extension.install")
	}
	if _, present := app["aps-environment"]; present {
		t.Fatal("direct app carries aps-environment; push is not used on macOS")
	}
	if _, present := app["com.apple.developer.aps-environment"]; present {
		t.Fatal("direct app carries com.apple.developer.aps-environment")
	}
	if stringList(app["com.apple.developer.applesignin"])[0] != "Default" {
		t.Fatal("direct app lost Sign in with Apple, which LoginInitialView uses")
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
		`appBundleIdentifier: "` + storeApp + `"`,
		`tunnelBundleIdentifier: "` + storeTunnel + `"`,
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
}
