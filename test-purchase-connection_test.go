package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// What a purchase does with the connection (ConnectViewModel.purchaseAroundConnection,
// which every surface's purchase goes through by ConnectionAwareSubscriptionStore) is
// Swift that can't be compiled here, so these tests read its sources. The Swift unit
// tests (PurchaseAroundConnectionTests, OutOfBalanceDisconnectFirstTests) run the
// behaviour. These check:
//   - only the Mac App Store build drops the connection for a purchase. The direct
//     download pays on a page that loads after the purchase call has returned, so a
//     drop around the call ended before the page asked for anything: it gained
//     nothing, left the traffic unprotected for a moment, and its notice's Cancel
//     stopped the purchase.
//   - with the kill switch on, the Mac App Store build tells the user to turn it off
//     and buys nothing. The kill switch keeps the tunnel up after the disconnect
//     (VPNDesiredState.shouldRun) and the sdk drops what it captures with no
//     connection, so the store still couldn't be reached, and the disconnect
//     notice's "won't go through the VPN" was wrong: the traffic was blocked.
//   - the kill switch the purchase reads is the setting as saved: the settings
//     toggle and the purchase read DeviceManager.routeLocal, which a launch left at
//     its default.
//   - the alert's words are in the catalog, in every locale.

func purchaseRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func purchaseRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(purchaseRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// The code of a Swift source with its comments gone: a word in a comment is not
// code. Lines that start a comment go, and what follows " // " on a line of code.
func purchaseCode(source string) string {
	var lines []string
	for _, line := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "*") || strings.HasPrefix(trimmed, "/*") {
			continue
		}
		if i := strings.Index(line, " // "); i >= 0 {
			line = line[:i]
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// The code with every run of white space one space, to compare a block as written.
func purchaseSquash(code string) string {
	return strings.Join(strings.Fields(code), " ")
}

// The block that opens with the first `{` of `start`, to its matching `}`.
func purchaseBody(t *testing.T, code string, start string) string {
	t.Helper()
	from := strings.Index(code, start)
	if from < 0 {
		t.Fatalf("no %q", start)
	}
	open := strings.Index(code[from:], "{")
	if open < 0 {
		t.Fatalf("%q opens no block", start)
	}
	depth := 0
	for i := from + open; i < len(code); i += 1 {
		switch code[i] {
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				return code[from+open : i+1]
			}
		}
	}
	t.Fatalf("%q is not closed", start)
	return ""
}

// The Swift under app/network, by path, with its comments gone.
func purchaseAppSources(t *testing.T) map[string]string {
	t.Helper()
	root := filepath.Join(purchaseRoot(t), "app/network")
	sources := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".swift") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		sources[rel] = purchaseCode(string(data))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) < 100 {
		t.Fatalf("CONTROL FAILED: read %d Swift sources", len(sources))
	}
	return sources
}

func TestPurchaseCodeLeavesTheCommentsOut(t *testing.T) {
	code := purchaseCode("// purchaseDropsConnection = true\n/**\n * purchaseDropsConnection = true\n */\nlet a = 1 // purchaseDropsConnection = true\nmodel.disconnect()")
	if strings.Contains(code, "purchaseDropsConnection") || !strings.Contains(code, "let a = 1") || !strings.Contains(code, "model.disconnect()") {
		t.Fatalf("the scan reads %q", code)
	}
	body := purchaseBody(t, "func f() { if a { b() } }\nfunc g() {}", "func f() {")
	if body != "{ if a { b() } }" {
		t.Fatalf("the block is %q", body)
	}
}

// Only the Mac App Store build drops the connection for a purchase, and the view
// model drops as its build does: the decision is the build's, not the platform's.
func TestOnlyTheMacAppStoreBuildDropsTheConnectionForAPurchase(t *testing.T) {
	distribution := purchaseCode(purchaseRead(t, "app/network/Shared/Billing/BillingDistribution.swift"))
	if !strings.Contains(distribution, "var purchaseDropsConnection: Bool {") {
		t.Error("BillingDistribution does not say which build drops the connection for a purchase")
	} else if drops := purchaseSquash(purchaseBody(t, distribution, "var purchaseDropsConnection: Bool {")); drops != "{ #if os(macOS) return self == .appStore #else return false #endif }" {
		t.Errorf("a purchase drops the connection on more than the Mac App Store build: %s", drops)
	}

	model := purchaseCode(purchaseRead(t, "app/network/Shared/ViewModels/ConnectViewModel.swift"))
	if strings.Count(model, "var purchaseDropsConnection = BillingDistribution.current.purchaseDropsConnection\n") != 1 {
		t.Error("the view model does not drop the connection as its build does")
	}
	if regexp.MustCompile(`purchaseDropsConnection\s*=\s*(true|false)`).MatchString(model) {
		t.Error("the view model fixes the drop for a whole platform, the direct download included")
	}
	flow := purchaseSquash(purchaseBody(t, model, "func purchaseAroundConnection(_ purchase: () async -> Void) async {"))
	if !strings.HasPrefix(flow, "{ guard purchaseDropsConnection else { await purchase() return }") {
		t.Errorf("a build that keeps the connection does not buy at once, with no notice and no disconnect: %s", flow)
	}

	// only the declaration sets it in the app; the tests stand in for the build
	assignment := regexp.MustCompile(`purchaseDropsConnection\s*=[^=]`)
	for path, code := range purchaseAppSources(t) {
		n := len(assignment.FindAllString(code, -1))
		if path == "Shared/ViewModels/ConnectViewModel.swift" {
			n -= 1
		}
		if n > 0 {
			t.Errorf("%s sets purchaseDropsConnection", path)
		}
	}
}

// the kill switch alert's words, as the Swift spells them
const (
	purchaseKillSwitchTitle   = "Turn off the kill switch to buy"
	purchaseKillSwitchMessage = "App Store purchases need the VPN disconnected, and while it's disconnected, the kill switch blocks your internet traffic. Turn off the kill switch, then try again. You can turn it back on afterward."
	purchaseKillSwitchButton  = "Got it"
)

// The flow reads the kill switch first: with it on and a tunnel there or coming,
// the user is told to turn it off, and nothing is dropped, asked or bought. A second
// tap while the alert is up does nothing, as for the notice.
func TestAKillSwitchThatIsOnIsToldBeforeAnyDisconnect(t *testing.T) {
	model := purchaseCode(purchaseRead(t, "app/network/Shared/ViewModels/ConnectViewModel.swift"))
	flow := purchaseSquash(purchaseBody(t, model, "func purchaseAroundConnection(_ purchase: () async -> Void) async {"))
	tell := strings.Index(flow, "if killSwitchOn() && (connectRequested || tunnelConnected) { await tellPurchaseNeedsKillSwitchOff() return }")
	if tell < 0 {
		t.Fatalf("the flow does not tell the user about the kill switch and stop: %s", flow)
	}
	running := strings.Index(flow, "purchaseAroundConnectionRunning = true")
	notice := strings.Index(flow, "await confirmPurchaseDisconnect()")
	drop := strings.Index(flow, "if dropped { disconnect() }")
	if running < 0 || notice < 0 || drop < 0 {
		t.Fatalf("CONTROL FAILED: the flow is not the one these tests read: %s", flow)
	}
	if !(running < tell && tell < notice && notice < drop) {
		t.Errorf("the kill switch is not read after the one-at-a-time guard and before the notice and the disconnect: %s", flow)
	}
	// the purchase after the disconnect is the flow's last; the kill switch returns before it
	if last := strings.LastIndex(flow, "await purchase()"); last < drop {
		t.Errorf("the store opens before the disconnect: %s", flow)
	}

	declarations := purchaseSquash(model)
	for _, declaration := range []string{
		"var killSwitchOn: @MainActor () -> Bool = { false }",
		"var tellPurchaseNeedsKillSwitchOff: () async -> Void = { await PurchaseKillSwitchNotice.show() }",
	} {
		if !strings.Contains(declarations, declaration) {
			t.Errorf("the view model does not declare %q", declaration)
		}
	}

	// the app reads the setting the toggle writes
	app := purchaseSquash(purchaseCode(purchaseRead(t, "app/network/NetworkApp.swift")))
	if !strings.Contains(app, "connectViewModel.killSwitchOn = { [weak deviceManager] in deviceManager?.routeLocal == false }") {
		t.Error("the app does not hand the purchase the kill switch setting")
	}
}

// The kill switch toggle shows DeviceManager.routeLocal, and the purchase reads it.
// A launch left it at its default, on, whatever was saved: the toggle showed the
// kill switch off while it was on, and the purchase would have read the same. The
// device's load sets it from the saved setting, without writing it back.
func TestTheKillSwitchSettingIsLoadedAsSaved(t *testing.T) {
	manager := purchaseSquash(purchaseCode(purchaseRead(t, "app/network/Shared/ViewModels/DeviceManager.swift")))
	if !strings.Contains(manager, "let routeLocal = localState.getRouteLocal()") || !strings.Contains(manager, "device.setRouteLocal(routeLocal)") {
		t.Fatal("CONTROL FAILED: the device's load does not read the saved setting")
	}
	if !strings.Contains(manager, "withDeviceStateLoad { self.blockerEnabled = blockerEnabled self.routeLocal = routeLocal }") {
		t.Error("the device's load leaves the kill switch setting at its default")
	}
	if !strings.Contains(manager, "@Published var routeLocal: Bool = true { didSet { guard !isLoadingFromDevice else { return } setRouteLocalInternal(routeLocal) } }") {
		t.Error("loading the kill switch setting writes it back")
	}
}

// The alert says to turn the kill switch off, with one button that buys nothing,
// and runs in the notice's modal loop so the main actor goes on meanwhile.
func TestTheKillSwitchAlertSaysToTurnItOff(t *testing.T) {
	store := purchaseCode(purchaseRead(t, "app/network/Shared/Billing/ConnectionAwareSubscriptionStore.swift"))
	notice := purchaseSquash(purchaseBody(t, store, "enum PurchaseKillSwitchNotice {"))
	for _, line := range []string{
		"static func show() async { #if os(macOS) _ = await PurchaseDisconnectNotice.answer(makeAlert()) #endif }",
		`alert.messageText = String(localized: "` + purchaseKillSwitchTitle + `")`,
		`alert.informativeText = String(localized: "` + purchaseKillSwitchMessage + `")`,
		`alert.addButton(withTitle: String(localized: "` + purchaseKillSwitchButton + `"))`,
	} {
		if !strings.Contains(notice, line) {
			t.Errorf("the kill switch alert does not have %s: %s", line, notice)
		}
	}
	if strings.Count(notice, "addButton(") != 1 {
		t.Errorf("the kill switch alert offers more than one button: %s", notice)
	}
	if strings.Contains(notice, "won't go through the VPN") {
		t.Error("the kill switch alert says the traffic goes around the VPN; it is blocked")
	}
}

// Every word of both purchase alerts is in the catalog, translated in every locale.
func TestThePurchaseAlertsAreInTheCatalog(t *testing.T) {
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
	if err := json.Unmarshal([]byte(purchaseRead(t, "app/network/Shared/Resources/Localizable.xcstrings")), &catalog); err != nil {
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
	for _, key := range []string{
		purchaseKillSwitchTitle,
		purchaseKillSwitchMessage,
		purchaseKillSwitchButton,
		"Disconnect the VPN for this purchase?",
		"URnetwork reconnects it afterward. Until it does, your internet traffic won't go through the VPN.",
		"Disconnect",
		"Cancel",
	} {
		entry, ok := catalog.Strings[key]
		if !ok {
			t.Errorf("the catalog has no %q", key)
			continue
		}
		if entry.ExtractionState == "stale" {
			t.Errorf("%q is stale", key)
		}
		for locale := range locales {
			if entry.Localizations[locale].StringUnit.Value == "" {
				t.Errorf("%q has no %s translation", key, locale)
			}
		}
	}
}
