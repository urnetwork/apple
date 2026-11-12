package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// The plan the plan cards show (support inbox 4074). In December 2025 the
// balance read failed under database load, and the app showed the failed read
// as Free, with Get Pro, to networks whose paid plans were running: the cards
// drew `isPro ? "Pro" : "Free"`, and isPro was false for any plan the server
// had not answered. The sdk decides the plan now (SubscriptionProTracker
// GetShownPlan, which DeviceManager publishes as shownPlan): only the server
// says Free, and a read that is on its way or failed is not known, which the
// cards show as a spinner or a retry. The Swift unit tests (ShownPlanTests)
// run the mapping and the sdk's tracker; this is Swift that can't be compiled
// here, so these tests read its sources:
//   - no card draws Free or Get Pro from isPro; the plan cards switch on the
//     shown plan, offer Get Pro only for Free, and retry a failed read;
//   - every balance read that fails reaches the sdk's decision, and every
//     input of the decision publishes the plan;
//   - the macOS introduction, which sells a plan, waits on a failed read as
//     the iOS one does.

func shownPlanRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func shownPlanRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(shownPlanRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// the text from the first `start` to the first `end` after it
func shownPlanBetween(t *testing.T, source string, start string, end string) string {
	t.Helper()
	from := strings.Index(source, start)
	if from < 0 {
		t.Fatalf("missing %q", start)
	}
	to := strings.Index(source[from:], end)
	if to < 0 {
		t.Fatalf("missing %q after %q", end, start)
	}
	return source[from : from+to]
}

func shownPlanContains(t *testing.T, name string, source string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(source, want) {
			t.Errorf("%s: missing %q", name, want)
		}
	}
}

func shownPlanLacks(t *testing.T, name string, source string, unwanted ...string) {
	t.Helper()
	for _, bad := range unwanted {
		if strings.Contains(source, bad) {
			t.Errorf("%s: still has %q", name, bad)
		}
	}
}

func TestNoViewDrawsFreeFromIsPro(t *testing.T) {
	freeFromIsPro := regexp.MustCompile(`isPro\s*\?\s*"Pro"\s*:\s*"Free"`)
	freeLabel := regexp.MustCompile(`Text\("Free"\)`)
	labels := 0
	root := filepath.Join(shownPlanRoot(t), "app", "network")
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if freeFromIsPro.Match(data) {
			t.Errorf("%s draws Free whenever isPro is false, also for a plan the server has not answered", rel)
		}
		labels += len(freeLabel.FindAll(data, -1))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// the Account plan card's, under its shown plan's .loaded (below)
	if labels != 1 {
		t.Errorf("%d Text(\"Free\") labels, want the Account plan card's 1", labels)
	}
}

func TestThePlanCardsShowAnUnknownPlanAsNotKnown(t *testing.T) {
	actions := shownPlanRead(t, "app/network/Main/Connect/ConnectActions/ConnectActions.swift")
	card := shownPlanBetween(t, actions, "private var planCard: some View {", "UsageBar(")
	shownPlanContains(t, "the connect plan card", card,
		"switch shownPlan.load",
		"SectionLoadFailedView(retry: retryPlan)",
		"ProgressView()",
		`Text(shownPlan == .pro ? "Pro" : "Free")`,
		"if shownPlan.offersUpgrade {",
	)
	shownPlanLacks(t, "the connect plan card", card, "if (!isPro)", `Text(isPro ? "Pro" : "Free")`)
	shownPlanContains(t, "ConnectActions", actions, "let shownPlan: ShownPlan", "var retryPlan: () -> Void")
	for _, view := range []string{
		"app/network/Main/Connect/ConnectView-iOS.swift",
		"app/network/Main/Connect/ConnectView-macOS.swift",
	} {
		shownPlanContains(t, view, shownPlanRead(t, view),
			"shownPlan: deviceManager.shownPlan,",
			"Task { await subscriptionBalanceViewModel.fetchSubscriptionBalance() }",
		)
	}

	account := shownPlanRead(t, "app/network/Main/Account/AccountRootView.swift")
	plan := shownPlanBetween(t, account, `Text("Plan")`, "manageSubscriptionAction(")
	shownPlanContains(t, "the account plan card", plan,
		"switch shownPlan.load",
		"ProgressView()",
		"if (shownPlan.offersUpgrade && !isGuest) {",
		"if !isGuest && shownPlan.load == .failed {",
		"SectionLoadFailedView(retry: {",
	)
	shownPlanLacks(t, "the account plan card", plan, "if (!isPro && !isGuest)", "if isPro {")
	// Free is drawn only once the server answered (.loaded)
	loaded := shownPlanBetween(t, plan, "case .loaded:", "Spacer()")
	shownPlanContains(t, "the account plan card's .loaded", loaded, `Text("Free")`, "if shownPlan == .pro {")
	shownPlanContains(t, "AccountRootView", account, "let shownPlan = deviceManager.shownPlan")
}

func TestShownPlanMapsOnlyTheServersFreeToFree(t *testing.T) {
	shown := shownPlanRead(t, "app/network/Shared/ViewModels/ShownPlan.swift")
	mapping := shownPlanBetween(t, shown, "static func of(sdkPlan: String, lastReadFailed: Bool) -> ShownPlan {", "var load: SectionLoad {")
	shownPlanContains(t, "ShownPlan.of", mapping,
		"case \"pro\":\n            return .pro",
		"case \"free\":\n            return .free",
		"default:\n            return lastReadFailed ? .unreachable : .loading",
	)
	if n := strings.Count(mapping, "return .free"); n != 1 {
		t.Errorf("ShownPlan.of returns .free %d times, want once, for the sdk's free", n)
	}
	upgrade := shownPlanBetween(t, shown, "var offersUpgrade: Bool {", "}")
	shownPlanContains(t, "ShownPlan.offersUpgrade", upgrade, "self == .free")
}

func TestAFailedBalanceReadReachesTheSdksDecision(t *testing.T) {
	model := shownPlanRead(t, "app/network/Shared/ViewModels/SubscriptionBalanceViewModel.swift")
	fetch := shownPlanBetween(t, model, "func fetchSubscriptionBalance() async {", "private func startBackgroundPolling()")
	failed := shownPlanBetween(t, fetch, "} catch(let error) {", "\n        }\n")
	shownPlanContains(t, "fetchSubscriptionBalance's failure", failed, "planReadFailed()")
	shownPlanContains(t, "SubscriptionBalanceViewModel", model,
		"private let planReadFailed: () -> Void",
		"self.planReadFailed = planReadFailed",
	)
	shownPlanContains(t, "MainView", shownPlanRead(t, "app/network/Main/MainView.swift"),
		"planReadFailed: subscriptionPlanFailed,",
	)
	shownPlanContains(t, "ContentView", shownPlanRead(t, "app/network/ContentView.swift"),
		"subscriptionPlanFailed: {\n                                deviceManager.subscriptionBalanceFailed()",
	)

	device := shownPlanRead(t, "app/network/Shared/ViewModels/DeviceManager.swift")
	publish := shownPlanBetween(t, device, "private func publishPlan(fallback: ShownPlan) {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.publishPlan", publish,
		"ShownPlan.of(sdkPlan: $0.getShownPlan(), lastReadFailed: $0.getLastReadFailed())",
		"setIsPro(plan == .pro)",
	)
	failure := shownPlanBetween(t, device, "func subscriptionBalanceFailed() {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.subscriptionBalanceFailed", failure, "proTracker?.balanceFailed()", "publishPlan(")
	loaded := shownPlanBetween(t, device, "func subscriptionBalanceLoaded(serverIsPro: Bool) -> Bool {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.subscriptionBalanceLoaded", loaded, "proTracker?.balanceLoaded(serverIsPro)", "publishPlan(")
	// every other input of the decision publishes the plan: the stored jwt,
	// and each reset (a sign out, a jwt that does not parse)
	jwt := shownPlanBetween(t, device, "private func updateParsedJwt() {", "func setCanShowRatingDialog(")
	if resets, publishes := strings.Count(jwt, "proTracker?.reset()"), strings.Count(jwt, "publishPlan("); resets != 2 || publishes != 3 {
		t.Errorf("updateParsedJwt: %d resets and %d plan publishes, want 2 and 3 (each reset and the stored jwt)", resets, publishes)
	}
	shownPlanLacks(t, "DeviceManager", device, "setIsPro(proTracker?.getIsPro()")
}

func TestTheMacIntroductionWaitsOnAFailedRead(t *testing.T) {
	split := shownPlanRead(t, "app/network/mac0S/Navigation/MainNavigationSplitView.swift")
	shownPlanContains(t, "MainNavigationSplitView", split, "balanceUnavailable: errorFetchingSubscriptionBalance")
	main := shownPlanRead(t, "app/network/Main/MainView.swift")
	mac := shownPlanBetween(t, main, "MainNavigationSplitView(", ")")
	shownPlanContains(t, "MainView's MainNavigationSplitView", mac,
		"errorFetchingSubscriptionBalance: subscriptionBalanceViewModel.errorFetchingSubscriptionBalance",
	)
}
