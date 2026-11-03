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

// Keep and Delete hide the words before anything is asked, so none can be read
// behind the device's authentication or the two-word check.
func TestBittensorKeyWordsHideBeforeTheConfirmation(t *testing.T) {
	model := bittensorKeySources(t)["BittensorKeyModel.swift"]
	explain := bittensorKeyBlock(t, model, strings.Index(model, "func explainDelete() {"))
	if hide, shown := strings.Index(explain, "hide()"), strings.Index(explain, "deleteExplained = true"); hide < 0 || shown < hide {
		t.Error("what deleting means shows before the words hide")
	}
	hide := bittensorKeyBlock(t, model, strings.Index(model, "func hide() {"))
	if !strings.Contains(hide, "flow.hide()") || !strings.Contains(hide, "refresh()") {
		t.Error("hide() no longer hides through the flow")
	}
	// the sdk's confirmations hide the words themselves, and ask nothing to start
	for _, name := range []string{"func confirmDelete() {", "func confirmKeep() {"} {
		body := bittensorKeyBlock(t, model, strings.Index(model, name))
		if strings.Contains(body, "authenticat") {
			t.Errorf("%s asks for device authentication", name)
		}
	}
	// deleting a stored key asks at its button, and only an authenticated answer reaches the flow
	submit := bittensorKeyBlock(t, model, strings.Index(model, "func submitWords(first: String, second: String) async {"))
	for _, line := range []string{"if screen.confirmNeedsAuthentication {", "guard authenticated else {", "flow.submitWords(first: first, second: second, authenticated: authenticated)"} {
		if !strings.Contains(submit, line) {
			t.Errorf("the check's button lost %s", line)
		}
	}
	screen := bittensorKeySources(t)["BittensorKeyScreen.swift"]
	main := bittensorKeyBlock(t, screen, strings.Index(screen, "    private var mainContent: some View {"))
	if !strings.Contains(main, "action: model.explainDelete") || !strings.Contains(main, "action: model.confirmKeep,") {
		t.Error("the Key screen's Delete and Keep don't go through the model")
	}
}

// Keep and Delete as drawn: Keep beside a coral-outlined Delete, what deleting means behind Continue,
// then the two words, with each wrong word named as it is typed and the button only for right ones.
func TestBittensorKeyConfirmationsAsDrawn(t *testing.T) {
	screen := bittensorKeySources(t)["BittensorKeyScreen.swift"]
	explanation := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyDeleteExplanation: View")
	for _, line := range []string{
		`Text("Delete the key from this device?")`,
		`Text("Set up payouts and delete the key?")`,
		`text: "Continue",`,
		"action: model.confirmDelete",
		"if model.screen.warnsTop200 {",
		"BittensorKeyWording()",
	} {
		if !strings.Contains(explanation, line) {
			t.Errorf("what deleting means lost %s", line)
		}
	}
	confirmation := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyConfirmation: View")
	for _, line := range []string{
		"model.checkWords(first: firstWord, second: secondWord)",
		"if state == SdkBittensorLocalKeyWordWrong {",
		`Text("That isn't word \(position) of this recovery phrase.")`,
		"enabled: check.ready,",
		"model.screen.confirmNeedsAuthentication ? BittensorDeviceAuthenticator.systemImage : nil",
		`text: "Keep it on this device",`,
	} {
		if !strings.Contains(confirmation, line) {
			t.Errorf("the two-word check lost %s", line)
		}
	}
	button := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyDestructiveButton: View")
	if !strings.Contains(button, ".background(filled ? themeManager.currentTheme.dangerColor : Color.clear)") || !strings.Contains(button, "Color.urBlack") {
		t.Error("the destructive button is not coral with dark text")
	}
}

// The payout card leads Earnings while it needs action, and Back up first, from Sign out, Delete
// account and the reminder, opens the Key screen.
func TestBittensorKeyCardLeadsAndBackUpFirstOpensTheKey(t *testing.T) {
	view := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsView.swift")
	lead, points, rest := strings.Index(view, "if keyModel.card.showsKeyPath {\n                        payoutCard"), strings.Index(view, "AccountPointsBreakdown("), strings.Index(view, "if !keyModel.card.showsKeyPath {\n                        payoutCard")
	if lead < 0 || points < lead || rest < points {
		t.Error("the payout card doesn't lead Earnings while it needs action")
	}
	if !strings.Contains(view, "if pending, deepLinkRouter.consumeEarningsKeyScreen() {\n                    keyModel.openKeyScreen()") {
		t.Error("Earnings doesn't open the Key screen it's asked for")
	}
	router := bittensorKeyRead(t, "app/network/Shared/ViewModels/DeepLinkRouter.swift")
	consume := bittensorKeyBlock(t, router, strings.Index(router, "func consumeEarningsKey() -> Bool {"))
	if !strings.Contains(consume, "pendingAccountPath = .earnings") || !strings.Contains(consume, "pendingEarningsKeyScreen = true") {
		t.Error("the router doesn't hand Earnings its Key screen")
	}
	for _, rel := range []string{"app/network/iOS/Navigation/MainTabView.swift", "app/network/mac0S/Navigation/MainNavigationSplitView.swift"} {
		if !strings.Contains(bittensorKeyRead(t, rel), "guard pending, deepLinkRouter.consumeEarningsKey() else { return }") {
			t.Errorf("%s doesn't take the Key screen's route", rel)
		}
	}
	signOut := bittensorKeySources(t)["BittensorKeySignOut.swift"]
	if !strings.Contains(signOut, `Button("Back up first") {`) || !strings.Contains(signOut, "deepLinkRouter.openEarningsKeyScreen()") || !strings.Contains(signOut, "content.confirmationDialog(") {
		t.Error("Sign out's warning has no Back up first")
	}
	settings := bittensorKeyRead(t, "app/network/Main/Account/Settings/SettingsView.swift")
	if strings.Count(settings, `Button("Back up first") {`) != 2 || strings.Count(settings, "deepLinkRouter.openEarningsKeyScreen()") != 2 {
		t.Error("Delete account's warnings have no Back up first")
	}
	delegate := bittensorKeyRead(t, "app/network/AppDelegate.swift")
	for _, line := range []string{
		"if response.notification.request.identifier == BittensorKeyReminderNotice.identifier {",
		"BittensorKeyReminderTaps.shared.tapped()",
		"completionHandler([])",
	} {
		if !strings.Contains(delegate, line) {
			t.Errorf("the reminder's tap lost %s", line)
		}
	}
	if got := strings.Count(delegate, "UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared"); got != 2 {
		t.Errorf("%d platforms set the notification delegate, want 2", got)
	}
	app := bittensorKeyRead(t, "app/network/NetworkApp.swift")
	if got := strings.Count(app, "if pending, BittensorKeyReminderTaps.shared.consume() {\n                        deepLinkRouter.openEarningsKeyScreen()"); got != 2 {
		t.Errorf("%d windows take the reminder's tap, want 2", got)
	}
}

// Claims through the relay: the tile and the sheet word what the sdk's claim status decides, and the
// device's own claim stays as the fallback.
func TestBittensorKeyClaimsThroughTheRelay(t *testing.T) {
	relay := bittensorKeyRead(t, "app/network/Main/Account/Earnings/ClaimRelaySheet.swift")
	for _, reason := range []string{
		"SdkSnClaimReasonUnderThreshold", "SdkSnClaimReasonQueued", "SdkSnClaimReasonCapReached", "SdkSnClaimReasonRefused",
		"SdkSnClaimReasonRelayNotRunning", "SdkSnClaimReasonRelayPaused",
		"SdkSnClaimNowReasonUnderFloor", "SdkSnClaimNowReasonRequested", "SdkSnClaimNowReasonLimit",
	} {
		if !strings.Contains(relay, "case "+reason+":") {
			t.Errorf("the claim screens don't word %s", reason)
		}
	}
	for _, line := range []string{"await viewModel.claimNow()", "if status.selfClaimAvailable {", "enabled: status.claimNowAvailable,"} {
		if !strings.Contains(relay, line) {
			t.Errorf("the claim screens lost %s", line)
		}
	}
	model := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift")
	if !strings.Contains(model, "claimNowOutcome = await client.claimNow(coldkeySs58: claimStatus.coldkeySs58)") || !strings.Contains(model, "await refreshClaimStatus()") {
		t.Error("Claim now doesn't go through the sdk")
	}
	client := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsClient.swift")
	if !strings.Contains(client, "device.snClaimStatus(") || !strings.Contains(client, "device.snClaimNow(") || !strings.Contains(client, "unavailable: result.error != nil") {
		t.Error("the client doesn't ask the sdk's claim relay")
	}
}

// The two-word fields: nothing the keyboard could learn the words from or
// suggest them with, on both platforms, and the confirmation uses them.
func TestBittensorKeyWordFieldsLearnNothing(t *testing.T) {
	screen := bittensorKeySources(t)["BittensorKeyScreen.swift"]
	confirmation := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyConfirmation: View")
	if !strings.Contains(confirmation, "BittensorKeyWordField(") || strings.Contains(confirmation, "TextField(") || strings.Contains(confirmation, "SecureField(") {
		t.Error("the two-word check doesn't use the quiet field")
	}
	ios := screen[strings.Index(screen, "struct BittensorKeyWordField: UIViewRepresentable"):strings.Index(screen, "struct BittensorKeyWordField: NSViewRepresentable")]
	for _, trait := range []string{
		"field.autocorrectionType = .no",
		"field.spellCheckingType = .no",
		"field.autocapitalizationType = .none",
		"field.smartQuotesType = .no",
		"field.smartDashesType = .no",
		"field.smartInsertDeleteType = .no",
		"field.keyboardType = .asciiCapable",
		"field.inlinePredictionType = .no",
		"Self.quiet(field)",
	} {
		if !strings.Contains(ios, trait) {
			t.Errorf("iOS: the word field lost %s", trait)
		}
	}
	mac := screen[strings.Index(screen, "struct BittensorKeyWordField: NSViewRepresentable"):]
	for _, trait := range []string{
		"editor.isAutomaticSpellingCorrectionEnabled = false",
		"editor.isContinuousSpellCheckingEnabled = false",
		"editor.isAutomaticQuoteSubstitutionEnabled = false",
		"editor.isAutomaticDashSubstitutionEnabled = false",
		"editor.isAutomaticTextReplacementEnabled = false",
		"editor.isAutomaticTextCompletionEnabled = false",
		"editor.inlinePredictionType = .no",
		"field.isAutomaticTextCompletionEnabled = false",
		"Self.quiet(editor)",
	} {
		if !strings.Contains(mac, trait) {
			t.Errorf("macOS: the word field lost %s", trait)
		}
	}
	// a quiet field is quiet before the first key: on focus, not on the first change
	focus := bittensorKeyBlock(t, mac, strings.Index(mac, "override func becomeFirstResponder() -> Bool {"))
	if !strings.Contains(focus, "Self.quiet(editor)") {
		t.Error("macOS quiets the field editor late")
	}
}

// After the one tap the wallet card and the points card show the key on this
// device, not a call to connect a second wallet.
func TestBittensorKeyWalletCardShowsTheKeyOnThisDevice(t *testing.T) {
	tiles := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsTiles.swift")
	card := bittensorKeyDeclaration(t, tiles, "", "struct BittensorWalletCard: View")
	key := strings.Index(card, "} else if let localKey {")
	connect := strings.Index(card, `UrButton(text: "Connect Bittensor wallet", action: connect)`)
	failed := strings.Index(card, "} else if loadFailed {")
	if key < 0 || connect < key || failed < 0 || key < failed {
		t.Error("the wallet card offers Connect Bittensor wallet beside the key on this device")
	}
	keyBranch := card[key:connect]
	for _, line := range []string{"shortAddress(localKey.address)", "connectSolanaItem", "if localKey.linked {"} {
		if !strings.Contains(keyBranch, line) {
			t.Errorf("the key's wallet card lost %s", line)
		}
	}
	if strings.Contains(keyBranch, "action: connect") {
		t.Error("the key's wallet card still connects a wallet")
	}
	local := bittensorKeyDeclaration(t, tiles, "", "struct BittensorWalletCardLocalKey: Equatable")
	for _, line := range []string{"guard !card.storedAddress.isEmpty else {", "linked = card.state == SdkBittensorLocalKeyStateSaveLaterLinked"} {
		if !strings.Contains(local, line) {
			t.Errorf("the wallet card's key lost %s", line)
		}
	}
	view := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsView.swift")
	if !strings.Contains(view, "localKey: BittensorWalletCardLocalKey(card: keyModel.card),") {
		t.Error("Earnings doesn't give the wallet card the key")
	}
	// the sdk's rule (BittensorLocalKeyCard.PaysKeyOnThisDevice), the one the ports read
	if !strings.Contains(view, "localKeyPaid: keyModel.card.paysKeyOnThisDevice") {
		t.Error("the points card still asks for a coldkey the key provides, or decides it apart from the sdk")
	}
	if strings.Contains(view, "localKeyPaid: keyModel.card.state") {
		t.Error("the points card decides by the card's state of its own")
	}
	seam := bittensorKeyRead(t, "app/network/Main/Account/Earnings/BittensorKey/BittensorKeyFlowSeam.swift")
	if !strings.Contains(seam, "paysKeyOnThisDevice: card.paysKeyOnThisDevice") {
		t.Error("the card doesn't carry the sdk's PaysKeyOnThisDevice")
	}
	model := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift")
	if !strings.Contains(model, "let hasColdkey = hasWallet || localKeyPaid") || !strings.Contains(model, "hasColdkey: hasColdkey,") {
		t.Error("the payout line doesn't count the key as a coldkey")
	}
}

// The Settlement v2 tile of a network with no wallet on this device follows the
// sdk's rule (SnClaimStatusResult.ShowsTile), the one the ports read: a claimable
// or pending balance, or a claim URnetwork paid in full, and nothing while the
// status can't be read. No balance arithmetic of the app's own.
func TestBittensorKeyClaimTileFollowsTheSdk(t *testing.T) {
	model := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift")
	tile := bittensorKeyDeclaration(t, model, "    ", "var ledgerTileWithRelay: SnLedgerTilePresentation? {")
	if !strings.Contains(tile, "guard let claimStatus, claimStatus.showsTile else {") {
		t.Error("the relay's tile is not the sdk's ShowsTile")
	}
	for _, own := range []string{"claimableRao + ", "pendingRao", "unavailable"} {
		if strings.Contains(tile, own) {
			t.Errorf("the relay's tile decides by %q of its own", own)
		}
	}
	client := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsClient.swift")
	if !strings.Contains(client, "showsTile: result.showsTile") {
		t.Error("the claim status doesn't carry the sdk's ShowsTile")
	}
}

// The claimed state as the mocks draw it (4d), when the sdk says (ShowsClaimed):
// the tile keeps the relay's section, which says so and opens the claim sheet;
// the sheet shows what URnetwork's claim paid and the key it is on, its
// transaction, when Claim now works again, Done, and the claim sheet's funds-only
// disclaimer.
func TestBittensorKeyClaimedStateAsDrawn(t *testing.T) {
	client := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsClient.swift")
	for _, line := range []string{"showsClaimed: result.showsClaimed", "claimTxUrl: result.claimTxUrl", "claimAmountRao: result.claimAmountRao"} {
		if !strings.Contains(client, line) {
			t.Errorf("the claim status doesn't carry %s", line)
		}
	}
	tiles := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsTiles.swift")
	if !strings.Contains(tiles, "relay.action != SdkSnClaimActionNone || 0 < relay.claimableRao || relay.showsClaimed {") {
		t.Error("the tile hides the relay's section in the claimed state")
	}
	sheet := bittensorKeyRead(t, "app/network/Main/Account/Earnings/ClaimRelaySheet.swift")
	section := bittensorKeyDeclaration(t, sheet, "", "struct SnClaimRelaySection: View {")
	claimedOnTile := strings.Index(section, "if status.showsClaimed {")
	if claimedOnTile < 0 || !strings.Contains(section[claimedOnTile:], "Button(action: claimNow) {") || !strings.Contains(section[claimedOnTile:], "SnClaimRelayClaimedText(status: status)") {
		t.Error("the tile's claimed state doesn't open the claim sheet")
	}
	text := bittensorKeyDeclaration(t, sheet, "", "struct SnClaimRelayClaimedText: View {")
	if !strings.Contains(text, `Text("Claimed by URnetwork. \(SnAlpha.formatAmount(rao: status.claimAmountRao)) SN25α is on your key, \(SnAlpha.shortSs58(status.coldkeySs58)).")`) {
		t.Error("the claimed sentence is not the mock's, from ClaimAmountRao and ColdkeySs58")
	}
	claimed := bittensorKeyDeclaration(t, sheet, "", "struct SnClaimRelayClaimed: View {")
	for _, line := range []string{"let url = URL(string: status.claimTxUrl)", "openURL(url)", `Text("Transaction")`} {
		if !strings.Contains(claimed, line) {
			t.Errorf("the claimed state's transaction link lost %s", line)
		}
	}
	againOn := bittensorKeyDeclaration(t, sheet, "", "struct SnClaimRelayAgainOn: View {")
	if !strings.Contains(againOn, `Text("Claim now is available again on \(SnClaimNowNote.date(status.claimNowNextAtMillis)).")`) {
		t.Error("the claimed state doesn't say when Claim now works again")
	}
	content := sheet[strings.Index(sheet, "private func content(_ status: SnClaimStatusInfo)"):]
	claimedInSheet := strings.Index(content, "if status.showsClaimed {")
	if claimedInSheet < 0 {
		t.Fatal("the claim sheet has no claimed state")
	}
	for _, line := range []string{"SnClaimRelayClaimed(status: status)", `UrButton(text: "Done", action: dismiss`, "SnClaimRelayAgainOn(status: status)"} {
		if !strings.Contains(content[claimedInSheet:], line) {
			t.Errorf("the claim sheet's claimed state lost %s", line)
		}
	}
	if !strings.Contains(sheet, "BittensorFundsDisclaimerText(disclaimer: fundsDisclaimer, boxed: true)") {
		t.Error("the claim sheet lost its funds disclaimer")
	}
	view := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsView.swift")
	if !strings.Contains(view, "fundsDisclaimer: keyModel.flow.fundsDisclaimer(at: SdkBittensorFundsDisclaimerPlaceClaimSheet),") {
		t.Error("the claim sheet's disclaimer is not the sdk's claim_sheet line, the funds-only one")
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
	if got := strings.Count(settings, "BittensorLocalKeyStore.shared.needsBackup("); got != 4 {
		t.Errorf("%d deletion confirmation parts warn, want 4: a message and Back up first in each", got)
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

// The key's words are every app's, so none names Apple's Keychain: Android,
// Windows and Linux keep the key elsewhere. A store that can't answer is the
// device's secure storage, as the funds disclaimer calls it.
func TestBittensorKeyWordsNameNoPlatformsStore(t *testing.T) {
	literal := regexp.MustCompile(`(?:Text\(|String\(localized: |UrButton\(\s*text: |text: |line\(|title\(|detail\(|note\(|Button\(|alert\(\s*|confirmationDialog\(\s*)"((?:[^"\\]|\\.)+)"`)
	seen := 0
	for name, source := range bittensorKeySources(t) {
		for _, match := range literal.FindAllStringSubmatch(source, -1) {
			seen += 1
			if strings.Contains(strings.ToLower(match[1]), "keychain") {
				t.Errorf("%s: %q names Apple's Keychain", name, match[1])
			}
		}
	}
	if seen < 30 {
		t.Fatalf("CONTROL FAILED: read %d literals", seen)
	}
	card := bittensorKeyRead(t, filepath.Join(bittensorKeySourcesDir, "BittensorKeyCard.swift"))
	if strings.Count(card, `"Couldn't read this device's secure storage. Unlock your device and try again."`) != 2 {
		t.Error("the card doesn't say secure storage where the store can't answer")
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
	literal := regexp.MustCompile(`(?:Text\(|String\(localized: |UrButton\(\s*text: |text: |line\(|title\(|detail\(|note\(|Button\(|alert\(\s*|confirmationDialog\(\s*)"((?:[^"\\]|\\.)+)"`)
	// a Swift interpolation is the catalog's %lld for these whole numbers, and %@ for any other value
	integers := map[string]bool{`\(position)`: true, `\(status.claimNowPeriodDays)`: true}
	interpolation := regexp.MustCompile(`\\\((?:[^()]|\([^()]*\))*\)`)
	scanned := map[string]string{}
	for name, source := range sources {
		scanned[name] = source
	}
	for _, rel := range []string{
		"app/network/Main/Account/Earnings/ClaimRelaySheet.swift",
		"app/network/Main/Account/Earnings/NetworkConsentSheet.swift",
	} {
		scanned[rel] = bittensorKeyRead(t, rel)
	}
	seen := 0
	for name, source := range scanned {
		for _, match := range literal.FindAllStringSubmatch(source, -1) {
			key := interpolation.ReplaceAllStringFunc(match[1], func(swift string) string {
				if integers[swift] {
					return "%lld"
				}
				return "%@"
			})
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

// The text of a Swift declaration at an indent, from its line to the first closing brace at that indent.
func bittensorKeyDeclaration(t *testing.T, source string, indent string, declaration string) string {
	t.Helper()
	start := strings.Index(source, "\n"+indent+declaration)
	if start < 0 {
		t.Fatalf("no %q", declaration)
	}
	end := strings.Index(source[start:], "\n"+indent+"}\n")
	if end < 0 {
		t.Fatalf("%q does not close", declaration)
	}
	return source[start : start+end]
}

// The text from the first "{" at or after start to its matching "}".
func bittensorKeyBlock(t *testing.T, source string, start int) string {
	t.Helper()
	if start < 0 {
		t.Fatal("no such block")
	}
	open := strings.Index(source[start:], "{")
	if open < 0 {
		t.Fatal("no block")
	}
	depth := 0
	for i := start + open; i < len(source); i++ {
		switch source[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return source[start+open : i+1]
			}
		}
	}
	t.Fatal("unbalanced block")
	return ""
}

// The owner's disclaimer (BTEASY.md, Wording; 2026-11-03), in plain view on every screen of the easy
// flows: the payout card, the Key screen and its delete and keep confirmations, and both claim cards. The
// sdk says which text a screen shows, so the app only draws what the flow's snapshot names. The words are
// the owner's, verbatim, and the catalog has them in every locale (TestBittensorKeyStringsAreInTheCatalog).
func TestBittensorFundsDisclaimerShowsOnEveryEasyFlowScreen(t *testing.T) {
	sources := bittensorKeySources(t)
	card := sources["BittensorKeyCard.swift"]
	for _, literal := range []string{
		`String(localized: "This key is stored locally in the app secure storage. It is never shared with URnetwork. URnetwork does not touch and is not responsible for any user funds.")`,
		`String(localized: "URnetwork does not touch and is not responsible for any user funds.")`,
		"case SdkBittensorFundsDisclaimerFull:",
		"case SdkBittensorFundsDisclaimerFundsOnly:",
	} {
		if !strings.Contains(card, literal) {
			t.Errorf("the disclaimer lost %s", literal)
		}
	}
	// plain text, never behind a link or a disclosure
	text := bittensorKeyBlock(t, card, strings.Index(card, "struct BittensorFundsDisclaimerText: View"))
	for _, hidden := range []string{"Link(", "DisclosureGroup", "Button(", ".popover", ".help(", "sheet"} {
		if strings.Contains(text, hidden) {
			t.Errorf("the disclaimer is behind %s", hidden)
		}
	}

	screen := sources["BittensorKeyScreen.swift"]
	main := bittensorKeyBlock(t, screen, strings.Index(screen, "    private var mainContent: some View {"))
	explanation := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyDeleteExplanation: View")
	confirmation := bittensorKeyDeclaration(t, screen, "", "struct BittensorKeyConfirmation: View")
	for name, block := range map[string]string{"the Key screen": main, "what deleting means": explanation, "the two-word check of delete and keep": confirmation} {
		if strings.Count(block, "BittensorFundsDisclaimerText(disclaimer: model.screen.fundsDisclaimer, boxed: true)") != 1 {
			t.Errorf("%s doesn't show the disclaimer once", name)
		}
	}
	// the check serves delete and keep alike, so both carry it
	if strings.Contains(bittensorKeyBlock(t, confirmation, strings.Index(confirmation, "if keeps {")), "BittensorFundsDisclaimerText(") {
		t.Error("only one of the confirmations shows the disclaimer")
	}

	tiles := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsTiles.swift")
	consentCard := bittensorKeyDeclaration(t, tiles, "", "struct NetworkConsentCard: View")
	if !strings.Contains(consentCard, "BittensorFundsDisclaimerText(disclaimer: key.fundsDisclaimer)") {
		t.Error("the payout card shows no disclaimer")
	}
	// once a screen: the claim tiles share Earnings with the payout card, so the sdk gives them the
	// disclaimer only while the payout card has none, and the first claim tile shown carries it
	for _, tile := range []string{"struct UnclaimedAlphaTile: View", "struct SnLedgerTile: View"} {
		block := bittensorKeyDeclaration(t, tiles, "", tile)
		if strings.Count(block, "BittensorFundsDisclaimerText(disclaimer: fundsDisclaimer)") != 1 ||
			!strings.Contains(block, "var fundsDisclaimer: String = SdkBittensorFundsDisclaimerNone") {
			t.Errorf("%s shows no disclaimer, or one of its own", tile)
		}
	}
	view := bittensorKeyRead(t, "app/network/Main/Account/Earnings/EarningsView.swift")
	unclaimedAt := strings.Index(view, "UnclaimedAlphaTile(")
	ledgerAt := strings.Index(view, "SnLedgerTile(")
	if unclaimedAt < 0 || ledgerAt < unclaimedAt || !strings.Contains(view[unclaimedAt-200:unclaimedAt], "if viewModel.hasWallet {") ||
		!strings.Contains(view[unclaimedAt:ledgerAt], "fundsDisclaimer: keyModel.card.claimFundsDisclaimer") ||
		!strings.Contains(view[ledgerAt:], "fundsDisclaimer: viewModel.hasWallet ? SdkBittensorFundsDisclaimerNone : keyModel.card.claimFundsDisclaimer") {
		t.Error("the claim tiles don't carry the disclaimer once, on the first one shown")
	}
	// the claim sheet is a screen of its own: the sdk's claim_sheet place
	relay := bittensorKeyRead(t, "app/network/Main/Account/Earnings/ClaimRelaySheet.swift")
	if !strings.Contains(relay, "BittensorFundsDisclaimerText(disclaimer: fundsDisclaimer, boxed: true)") ||
		!strings.Contains(view, "fundsDisclaimer: keyModel.flow.fundsDisclaimer(at: SdkBittensorFundsDisclaimerPlaceClaimSheet)") {
		t.Error("the claim sheet shows no disclaimer")
	}
	consentSheet := bittensorKeyRead(t, "app/network/Main/Account/Earnings/NetworkConsentSheet.swift")
	if !strings.Contains(consentSheet, "BittensorFundsDisclaimerText(disclaimer: createKeyDisclaimer, boxed: true)") ||
		!strings.Contains(view, "createKeyDisclaimer: keyModel.flow.fundsDisclaimer(at: SdkBittensorFundsDisclaimerPlaceChangeWallet)") {
		t.Error("Change wallet's offer of a key shows no disclaimer")
	}
	// what deleting means, and the check, replace the Key screen, so one disclaimer shows at a time
	if !strings.Contains(screen, "if model.screen.confirming != SdkBittensorLocalKeyConfirmNone {\n                        BittensorKeyConfirmation(model: model)\n                    } else if model.deleteExplained {\n                        BittensorKeyDeleteExplanation(model: model)\n                    } else {\n                        mainContent") {
		t.Error("the confirmations no longer replace the Key screen, so two disclaimers could show")
	}

	seam := sources["BittensorKeyFlowSeam.swift"]
	for _, mapping := range []string{
		"fundsDisclaimer: card.fundsDisclaimer,",
		"claimFundsDisclaimer: card.claimFundsDisclaimer",
		"fundsDisclaimer: screen.fundsDisclaimer",
		"flow?.fundsDisclaimer(at: place)",
	} {
		if !strings.Contains(seam, mapping) {
			t.Errorf("the seam does not carry %s", mapping)
		}
	}
}
