package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// The payout key's Apple side (BTEASY.md) is Swift and entitlements that can't
// run here, so these tests read them. The Swift unit tests run the behaviour,
// and the flow's own rules are tested in the sdk
// (bittensor_local_key_flow_test.go). These check what a test run can't see:
//   - the Keychain group is the app's alone, both Mac builds name it, and the
//     tunnel's group stays first;
//   - the store keeps the item on this device;
//   - nothing in the key's Swift can log, persist or hand the words to anything
//     but the screen and an explicit Copy;
//   - the decisions stay in the sdk: the app makes no key and signs nothing itself;
//   - sign out and account deletion go through their warnings, and sign out
//     leaves the item alone;
//   - every word on these screens is in the catalog, in every locale.

const (
	bittensorKeyGroup      = "$(AppIdentifierPrefix)network.ur.bittensor-key"
	bittensorKeySourcesDir = "app/network/Main/Account/Earnings/BittensorKey"
)

func bittensorKeyRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func bittensorKeyRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(bittensorKeyRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// The Swift of the key, by file name, without its comments: a word in a comment
// is not code.
func bittensorKeySources(t *testing.T) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(bittensorKeyRoot(t), bittensorKeySourcesDir))
	if err != nil {
		t.Fatal(err)
	}
	sources := map[string]string{}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".swift") {
			continue
		}
		var code strings.Builder
		for _, line := range strings.Split(bittensorKeyRead(t, filepath.Join(bittensorKeySourcesDir, entry.Name())), "\n") {
			if !strings.HasPrefix(strings.TrimSpace(line), "//") {
				code.WriteString(line + "\n")
			}
		}
		sources[entry.Name()] = code.String()
	}
	if len(sources) < 5 {
		t.Fatalf("CONTROL FAILED: read %d files", len(sources))
	}
	return sources
}

func bittensorKeyGroups(t *testing.T, rel string) []string {
	t.Helper()
	data := bittensorKeyRead(t, rel)
	start := strings.Index(data, "<key>keychain-access-groups</key>")
	if start < 0 {
		return nil
	}
	end := strings.Index(data[start:], "</array>")
	return regexp.MustCompile(`<string>([^<]*)</string>`).FindAllString(data[start:start+end], -1)
}

// Both Mac builds and iOS name the group, after the tunnel's, which stays first
// since an item added with no group goes there. Nothing else has it: an extension
// that could read the Keychain item could read the phrase.
func TestBittensorKeyGroupIsTheAppsAlone(t *testing.T) {
	for rel, tunnelGroup := range map[string]string{
		"app/network/network.entitlements":              "$(AppIdentifierPrefix)network.ur.tunnel-credentials",
		"app/network/network-macOS.entitlements":        "$(AppIdentifierPrefix)network.ur.tunnel-credentials",
		"app/network/network-macOS-direct.entitlements": "$(AppIdentifierPrefix)com.bringyour.urnetwork.tunnel-credentials",
	} {
		want := []string{"<string>" + tunnelGroup + "</string>", "<string>" + bittensorKeyGroup + "</string>"}
		if got := bittensorKeyGroups(t, rel); !slices.Equal(got, want) {
			t.Errorf("%s: keychain-access-groups %v, want %v", rel, got, want)
		}
	}

	seen := 0
	err := filepath.Walk(filepath.Join(bittensorKeyRoot(t), "app"), func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() && (info.Name() == "build" || info.Name() == "app.xcodeproj") {
			return filepath.SkipDir
		}
		if info.IsDir() || !strings.HasSuffix(path, ".entitlements") {
			return nil
		}
		seen += 1
		switch filepath.Base(path) {
		case "network.entitlements", "network-macOS.entitlements", "network-macOS-direct.entitlements":
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(data), "bittensor-key") {
			t.Errorf("%s can read the payout key", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if seen < 8 {
		t.Fatalf("CONTROL FAILED: read %d entitlements files", seen)
	}
}

// The plist names the group from a setting both app targets carry, in each
// configuration, so the store finds it in either build.
func TestBittensorKeyBuildSettingsNameTheGroup(t *testing.T) {
	plist := bittensorKeyRead(t, "app/URnetwork-Info.plist")
	if !strings.Contains(plist, "<key>URBittensorKeyKeychainAccessGroup</key>\n\t<string>$(UR_BITTENSOR_KEY_KEYCHAIN_ACCESS_GROUP)</string>") {
		t.Error("URnetwork-Info.plist does not name the group")
	}
	project := bittensorKeyRead(t, "app/app.xcodeproj/project.pbxproj")
	setting := `UR_BITTENSOR_KEY_KEYCHAIN_ACCESS_GROUP = "` + bittensorKeyGroup + `";`
	if got := strings.Count(project, setting); got != 4 {
		t.Errorf("%d configurations set the group, want 4: Debug and Release of both app targets", got)
	}
	if got := strings.Count(project, "INFOPLIST_KEY_NSFaceIDUsageDescription"); got != 4 {
		t.Errorf("%d configurations say why Face ID is used, want 4", got)
	}
	store := bittensorKeySources(t)["BittensorLocalKeyStore.swift"]
	if !strings.Contains(store, `static let accessGroupInfoKey = "URBittensorKeyKeychainAccessGroup"`) {
		t.Error("the store reads another Info.plist key")
	}
}

// The item is on this device only, in the data protection keychain, unsynced,
// and an add can't replace one.
func TestBittensorKeyStoreKeepsTheItemOnThisDevice(t *testing.T) {
	store := bittensorKeySources(t)["BittensorLocalKeyStore.swift"]
	for _, line := range []string{
		"attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
		"kSecUseDataProtectionKeychain as String: true,",
		"kSecAttrSynchronizable as String: false,",
		"kSecAttrAccessGroup as String: accessGroup,",
		"kSecAttrAccount as String: networkId,",
		"return keychain.add(attributes) == errSecSuccess",
	} {
		if !strings.Contains(store, line) {
			t.Errorf("the store lost %q", line)
		}
	}
	for _, forbidden := range []string{"SecItemUpdate", "kSecAttrAccessibleAfterFirstUnlock", "kSecAttrAccessibleAlways", "kSecAttrSynchronizable as String: true"} {
		if strings.Contains(store, forbidden) {
			t.Errorf("the store uses %s", forbidden)
		}
	}
}

// The phrase's only way out of the flow is the screen and an explicit Copy.
func TestBittensorKeySourcesHoldNoWayToLeakTheWords(t *testing.T) {
	for name, source := range bittensorKeySources(t) {
		for _, forbidden := range []string{
			"print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump(",
			".textSelection", "TextEditor", "NSUserActivity", ".userActivity(", "@SceneStorage", "@AppStorage",
			"UserDefaults.standard.set", "ClientEvents", "Crashlytics", "write(to:", "FileManager",
		} {
			if strings.Contains(source, forbidden) {
				t.Errorf("%s uses %s", name, forbidden)
			}
		}
		if name != "BittensorKeyPlatform.swift" && (strings.Contains(source, "UIPasteboard") || strings.Contains(source, "NSPasteboard")) {
			t.Errorf("%s reaches a pasteboard itself", name)
		}
	}
	platform := bittensorKeySources(t)["BittensorKeyPlatform.swift"]
	for _, line := range []string{".localOnly: true,", ".expirationDate:", "prepareForNewContents(with: .currentHostOnly)", "org.nspasteboard.ConcealedType"} {
		if !strings.Contains(platform, line) {
			t.Errorf("the pasteboard lost %q", line)
		}
	}
	// the words are plain Text, built only while they show
	screen := bittensorKeySources(t)["BittensorKeyScreen.swift"]
	revealed := strings.Index(screen, "if model.screen.revealed {")
	grid := strings.Index(screen, "BittensorKeyProtectedWords(words: model.words")
	if revealed < 0 || grid < revealed {
		t.Error("the words are in the view tree while hidden")
	}
	if !strings.Contains(screen, "BittensorKeyCaptureProtected(content: grid)") {
		t.Error("iOS draws the words outside the secure layer")
	}
	if !strings.Contains(screen, "window.sharingType = .none") {
		t.Error("macOS leaves the window open to capture")
	}
	if !strings.Contains(screen, "UIScreen.capturedDidChangeNotification") || !strings.Contains(screen, "UIApplication.userDidTakeScreenshotNotification") {
		t.Error("iOS does not watch for capture and screenshots")
	}

	// nothing outside the key's folder in the app, and nothing in the extensions, touches it
	for _, directory := range []string{"app/extension", "app/widgets", "app/splittunnel", "app/URnetworkLaunchHelper"} {
		err := filepath.Walk(filepath.Join(bittensorKeyRoot(t), directory), func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || !strings.HasSuffix(path, ".swift") {
				return err
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if strings.Contains(string(data), "BittensorLocalKey") || strings.Contains(string(data), "BittensorKey") {
				t.Errorf("%s reaches the payout key", path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

// The sdk decides. The app reads what to show from it and makes no key and signs
// nothing of its own, so the ports get the same rules.
func TestBittensorKeyDecisionsStayInTheSdk(t *testing.T) {
	err := filepath.Walk(filepath.Join(bittensorKeyRoot(t), "app/network"), func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, forbidden := range []string{"SdkBittensorLocalKeyGenerate", "SdkBittensorLocalKeySign"} {
			if strings.Contains(string(data), forbidden) {
				t.Errorf("%s calls %s: only the sdk's flow makes a key or signs with one", path, forbidden)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	seam := bittensorKeySources(t)["BittensorKeyFlowSeam.swift"]
	if !strings.Contains(seam, "SdkNewBittensorLocalKeyFlow(api, networkId ?? \"\", store)") {
		t.Error("the seam does not make the sdk's flow")
	}
	// the app's own consent path stays the wallets'
	consent := bittensorKeyRead(t, "app/network/Main/Account/Earnings/NetworkConsentFlow.swift")
	if strings.Contains(consent, "BittensorLocalKey") {
		t.Error("the wallet flow reaches the key")
	}
}

// Sign out warns through one guard, the alert is at the root, and account deletion
// warns then forgets the key before it signs out. A logout itself never mentions the
// key: the item stays.
func TestBittensorKeySignOutAndAccountDeletion(t *testing.T) {
	content := bittensorKeyRead(t, "app/network/ContentView.swift")
	if !strings.Contains(content, "BittensorKeySignOut.shared.request(networkId: networkId?.idStr)") || !strings.Contains(content, ".modifier(BittensorKeySignOutAlert())") {
		t.Error("the app's Sign out does not go through the warning")
	}
	app := bittensorKeyRead(t, "app/network/NetworkApp.swift")
	if !strings.Contains(app, "BittensorKeySignOut.shared.request(networkId: deviceManager.parsedJwt?.networkId?.idStr)") {
		t.Error("the Account menu's Sign out does not go through the warning")
	}
	sessions := bittensorKeyRead(t, "app/network/Main/Account/Sessions/SessionsView.swift")
	if !strings.Contains(sessions, "confirmation.message(keyNeedsBackup: BittensorLocalKeyStore.shared.needsBackup(") {
		t.Error("the sessions screen's sign out does not warn")
	}
	settings := bittensorKeyRead(t, "app/network/Main/Account/Settings/SettingsView.swift")
	forget := strings.Index(settings, "BittensorLocalKeyStore.shared.forgetNetwork(")
	logout := strings.Index(settings, "deviceManager.logout()")
	if forget < 0 || logout < forget {
		t.Error("account deletion does not forget the key before it signs out")
	}
	if got := strings.Count(settings, "BittensorLocalKeyStore.shared.needsBackup("); got != 2 {
		t.Errorf("%d deletion confirmations warn, want 2", got)
	}
	for _, rel := range []string{
		"app/network/Shared/ViewModels/DeviceManager.swift",
		"app/network/Shared/ViewModels/VPNManager.swift",
		"app/network/Shared/ViewModels/ConnectViewModel.swift",
	} {
		if strings.Contains(bittensorKeyRead(t, rel), "BittensorLocalKey") {
			t.Errorf("%s reaches the payout key: a logout must leave it", rel)
		}
	}
}

// The words the plan fixes, spelled as it spells them, and every literal on these
// screens in the catalog in every locale it ships.
func TestBittensorKeyStringsAreInTheCatalog(t *testing.T) {
	var catalog struct {
		Strings map[string]struct {
			ExtractionState string `json:"extractionState"`
			Localizations   map[string]struct {
				StringUnit struct {
					Value string `json:"value"`
				} `json:"stringUnit"`
			} `json:"localizations"`
		} `json:"strings"`
	}
	if err := json.Unmarshal([]byte(bittensorKeyRead(t, "app/network/Shared/Resources/Localizable.xcstrings")), &catalog); err != nil {
		t.Fatal(err)
	}
	locales := map[string]bool{}
	for _, entry := range catalog.Strings {
		for locale := range entry.Localizations {
			locales[locale] = true
		}
	}
	if !locales["zh-Hans"] || len(locales) < 27 {
		t.Fatalf("the catalog ships %d locales", len(locales))
	}

	sources := bittensorKeySources(t)
	var all strings.Builder
	for _, source := range sources {
		all.WriteString(source)
	}
	for _, rel := range []string{
		"app/network/Main/Account/Earnings/EarningsView.swift",
		"app/network/Main/Account/Settings/SettingsView.swift",
	} {
		all.WriteString(bittensorKeyRead(t, rel))
	}
	for _, line := range []string{
		"URnetwork is not a wallet. It created this key so you can receive SN25α. To transfer or use your SN25α, enter this recovery phrase into a Bittensor wallet such as Talisman or Nova, or into btcli.",
		"Anyone with this phrase controls your SN25α. URnetwork will never ask for it, and can't recover it. If you lose this device before saving it, your SN25α can't be reached.",
		"Deleting this key also gives up claiming a Top 200 spot with one tap. You could still claim from a Bittensor wallet holding this recovery phrase.",
		"I have saved the key, it's OK to delete it now.",
		"Set up payouts",
		"Save the recovery phrase first",
		"Use a wallet I already have",
		"Payouts start next epoch",
		"Back up your key",
		"This app no longer has the key",
		"Tap to reveal",
	} {
		if !strings.Contains(all.String(), `"`+line+`"`) {
			t.Errorf("no call site spells %q", line)
		}
	}

	// the literals a SwiftUI Text, a button or String(localized:) looks up
	literal := regexp.MustCompile(`(?:Text\(|String\(localized: |UrButton\(\s*text: |text: |line\(|Button\(|alert\(\s*)"((?:[^"\\]|\\.)+)"`)
	seen := 0
	for name, source := range sources {
		for _, match := range literal.FindAllStringSubmatch(source, -1) {
			key := strings.ReplaceAll(match[1], `\(position)`, "%lld")
			key = strings.ReplaceAll(key, `\"`, `"`)
			seen += 1
			entry, ok := catalog.Strings[key]
			if !ok {
				t.Errorf("%s: the catalog has no %q", name, key)
				continue
			}
			if entry.ExtractionState == "stale" {
				t.Errorf("%s: %q is stale", name, key)
			}
			for locale := range locales {
				if entry.Localizations[locale].StringUnit.Value == "" {
					t.Errorf("%s: %q has no %s translation", name, key, locale)
				}
			}
		}
	}
	if seen < 30 {
		t.Fatalf("CONTROL FAILED: read %d literals", seen)
	}
}

// The card offers the key's paths from what the flow says, the banner stays while
// unsaved, and a session that can't make a key keeps the wallet card.
func TestBittensorKeyCardComesFromTheFlow(t *testing.T) {
	view := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsView.swift")
	for _, line := range []string{
		"if keyModel.card.backupReminder {",
		"key: keyModel.card,",
		"keyModel.consentRead(status, fromEpoch: fromEpoch)",
		"BittensorKeyScreen(model: keyModel, dismiss: keyModel.closeScreen)",
		".interactiveDismissDisabled(keyModel.screen.busy)",
	} {
		if !strings.Contains(view, line) {
			t.Errorf("Earnings lost %q", line)
		}
	}
	tiles := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsTiles.swift")
	if !strings.Contains(tiles, "if let key, let keyActions, key.showsKeyPath {") {
		t.Error("the card no longer decides from the flow")
	}
	nav := bittensorKeyRead(t, "app/network/Main/Account/AccountNavStackView.swift")
	if !strings.Contains(nav, "SdkBittensorKeyFlow(api: api, networkId: networkId, store: .shared)") {
		t.Error("the nav stack does not give Earnings the sdk's flow")
	}
}
