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
package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// The repository root: the directory of this file.
func shownPlanRoot(t *testing.T) string {
	t.Helper()
	_, sourcePath, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(sourcePath)
}

// A source file's text, by its path from the repository root.
func shownPlanRead(t *testing.T, relPath string) string {
	t.Helper()
	sourceBytes, err := os.ReadFile(filepath.Join(shownPlanRoot(t), relPath))
	if err != nil {
		t.Fatal(err)
	}
	return string(sourceBytes)
}

// The text from the first startMarker to the first endMarker after it.
func shownPlanBetween(t *testing.T, source string, startMarker string, endMarker string) string {
	t.Helper()
	fromIndex := strings.Index(source, startMarker)
	if fromIndex < 0 {
		t.Fatalf("missing %q", startMarker)
	}
	toIndex := strings.Index(source[fromIndex:], endMarker)
	if toIndex < 0 {
		t.Fatalf("missing %q after %q", endMarker, startMarker)
	}
	return source[fromIndex : fromIndex+toIndex]
}

// Reports each wanted snippet the source does not have.
func shownPlanContains(t *testing.T, name string, source string, wantSnippets ...string) {
	t.Helper()
	for _, snippet := range wantSnippets {
		if !strings.Contains(source, snippet) {
			t.Errorf("%s: missing %q", name, snippet)
		}
	}
}

// Reports each unwanted snippet the source still has.
func shownPlanLacks(t *testing.T, name string, source string, unwantedSnippets ...string) {
	t.Helper()
	for _, snippet := range unwantedSnippets {
		if strings.Contains(source, snippet) {
			t.Errorf("%s: still has %q", name, snippet)
		}
	}
}

// No view takes Free from isPro, which is false for a plan the server has not
// answered; the one Free label left is the Account card's.
func TestNoViewDrawsFreeFromIsPro(t *testing.T) {
	freeFromIsProRegexp := regexp.MustCompile(`isPro\s*\?\s*"Pro"\s*:\s*"Free"`)
	freeLabelRegexp := regexp.MustCompile(`Text\("Free"\)`)
	freeLabelCount := 0
	networkPath := filepath.Join(shownPlanRoot(t), "app", "network")
	err := filepath.WalkDir(networkPath, func(filePath string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(filePath, ".swift") {
			return err
		}
		sourceBytes, err := os.ReadFile(filePath)
		if err != nil {
			return err
		}
		relPath, _ := filepath.Rel(networkPath, filePath)
		if freeFromIsProRegexp.Match(sourceBytes) {
			t.Errorf("%s draws Free whenever isPro is false, also for a plan the server has not answered", relPath)
		}
		freeLabelCount += len(freeLabelRegexp.FindAll(sourceBytes, -1))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// the Account plan card's, under its shown plan's .loaded
	if freeLabelCount != 1 {
		t.Errorf("%d Text(\"Free\") labels, want the Account plan card's 1", freeLabelCount)
	}
}

// The connect and Account plan cards switch on the shown plan: a spinner while
// it loads, a retry once a read failed, and Get Pro only for Free.
func TestThePlanCardsShowAnUnknownPlanAsNotKnown(t *testing.T) {
	actionsSource := shownPlanRead(t, "app/network/Main/Connect/ConnectActions/ConnectActions.swift")
	cardSource := shownPlanBetween(t, actionsSource, "private var planCard: some View {", "UsageBar(")
	shownPlanContains(t, "the connect plan card", cardSource,
		"switch shownPlan.load",
		"SectionLoadFailedView(retry: retryPlan)",
		"ProgressView()",
		`Text(shownPlan == .pro ? "Pro" : "Free")`,
		"if shownPlan.offersUpgrade {",
	)
	shownPlanLacks(t, "the connect plan card", cardSource, "if (!isPro)", `Text(isPro ? "Pro" : "Free")`)
	shownPlanContains(t, "ConnectActions", actionsSource, "let shownPlan: ShownPlan", "var retryPlan: () -> Void")
	for _, viewPath := range []string{
		"app/network/Main/Connect/ConnectView-iOS.swift",
		"app/network/Main/Connect/ConnectView-macOS.swift",
	} {
		shownPlanContains(t, viewPath, shownPlanRead(t, viewPath),
			"shownPlan: deviceManager.shownPlan,",
			"Task { await subscriptionBalanceViewModel.fetchSubscriptionBalance() }",
		)
	}

	accountSource := shownPlanRead(t, "app/network/Main/Account/AccountRootView.swift")
	planSource := shownPlanBetween(t, accountSource, `Text("Plan")`, "manageSubscriptionAction(")
	shownPlanContains(t, "the account plan card", planSource,
		"switch shownPlan.load",
		"ProgressView()",
		"if (shownPlan.offersUpgrade && !isGuest) {",
		"if !isGuest && shownPlan.load == .failed {",
		"SectionLoadFailedView(retry: {",
	)
	shownPlanLacks(t, "the account plan card", planSource, "if (!isPro && !isGuest)", "if isPro {")
	// Free is drawn only once the server answered (.loaded)
	loadedSource := shownPlanBetween(t, planSource, "case .loaded:", "Spacer()")
	shownPlanContains(t, "the account plan card's .loaded", loadedSource, `Text("Free")`, "if shownPlan == .pro {")
	shownPlanContains(t, "AccountRootView", accountSource, "let shownPlan = deviceManager.shownPlan")
}

// The mapping from the sdk's strings gives .free for the sdk's free alone, and
// only Free offers Get Pro.
func TestShownPlanMapsOnlyTheServersFreeToFree(t *testing.T) {
	shownSource := shownPlanRead(t, "app/network/Shared/ViewModels/ShownPlan.swift")
	mappingSource := shownPlanBetween(t, shownSource, "static func of(sdkPlan: String, lastReadFailed: Bool) -> ShownPlan {", "var load: SectionLoad {")
	shownPlanContains(t, "ShownPlan.of", mappingSource,
		"case \"pro\":\n            return .pro",
		"case \"free\":\n            return .free",
		"default:\n            return lastReadFailed ? .unreachable : .loading",
	)
	if freeReturnCount := strings.Count(mappingSource, "return .free"); freeReturnCount != 1 {
		t.Errorf("ShownPlan.of returns .free %d times, want once, for the sdk's free", freeReturnCount)
	}
	upgradeSource := shownPlanBetween(t, shownSource, "var offersUpgrade: Bool {", "}")
	shownPlanContains(t, "ShownPlan.offersUpgrade", upgradeSource, "self == .free")
}

// A failed read reaches the sdk's decision through the view model, MainView and
// ContentView, and each input of the decision publishes the plan.
func TestAFailedBalanceReadReachesTheSdksDecision(t *testing.T) {
	modelSource := shownPlanRead(t, "app/network/Shared/ViewModels/SubscriptionBalanceViewModel.swift")
	fetchSource := shownPlanBetween(t, modelSource, "func fetchSubscriptionBalance() async {", "private func startBackgroundPolling()")
	failedSource := shownPlanBetween(t, fetchSource, "} catch(let error) {", "\n        }\n")
	shownPlanContains(t, "fetchSubscriptionBalance's failure", failedSource, "planReadFailed()")
	shownPlanContains(t, "SubscriptionBalanceViewModel", modelSource,
		"private let planReadFailed: () -> Void",
		"self.planReadFailed = planReadFailed",
	)
	shownPlanContains(t, "MainView", shownPlanRead(t, "app/network/Main/MainView.swift"),
		"planReadFailed: subscriptionPlanFailed,",
	)
	shownPlanContains(t, "ContentView", shownPlanRead(t, "app/network/ContentView.swift"),
		"subscriptionPlanFailed: {\n                                deviceManager.subscriptionBalanceFailed()",
	)

	deviceSource := shownPlanRead(t, "app/network/Shared/ViewModels/DeviceManager.swift")
	publishSource := shownPlanBetween(t, deviceSource, "private func publishPlan(fallback: ShownPlan) {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.publishPlan", publishSource,
		"ShownPlan.of(sdkPlan: $0.getShownPlan(), lastReadFailed: $0.getLastReadFailed())",
		"setIsPro(plan == .pro)",
	)
	failureSource := shownPlanBetween(t, deviceSource, "func subscriptionBalanceFailed() {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.subscriptionBalanceFailed", failureSource, "proTracker?.balanceFailed()", "publishPlan(")
	loadedSource := shownPlanBetween(t, deviceSource, "func subscriptionBalanceLoaded(serverIsPro: Bool) -> Bool {", "\n    }\n")
	shownPlanContains(t, "DeviceManager.subscriptionBalanceLoaded", loadedSource, "proTracker?.balanceLoaded(serverIsPro)", "publishPlan(")
	// the stored jwt and each reset (a sign out, a jwt that does not parse)
	// publish the plan too
	jwtSource := shownPlanBetween(t, deviceSource, "private func updateParsedJwt() {", "func setCanShowRatingDialog(")
	resetCount := strings.Count(jwtSource, "proTracker?.reset()")
	publishCount := strings.Count(jwtSource, "publishPlan(")
	if resetCount != 2 || publishCount != 3 {
		t.Errorf("updateParsedJwt: %d resets and %d plan publishes, want 2 and 3 (each reset and the stored jwt)", resetCount, publishCount)
	}
	shownPlanLacks(t, "DeviceManager", deviceSource, "setIsPro(proTracker?.getIsPro()")
}

// The macOS introduction, which sells a plan, waits on a failed balance read as
// the iOS one does.
func TestTheMacIntroductionWaitsOnAFailedRead(t *testing.T) {
	splitSource := shownPlanRead(t, "app/network/mac0S/Navigation/MainNavigationSplitView.swift")
	shownPlanContains(t, "MainNavigationSplitView", splitSource, "balanceUnavailable: errorFetchingSubscriptionBalance")
	mainSource := shownPlanRead(t, "app/network/Main/MainView.swift")
	macSource := shownPlanBetween(t, mainSource, "MainNavigationSplitView(", ")")
	shownPlanContains(t, "MainView's MainNavigationSplitView", macSource,
		"errorFetchingSubscriptionBalance: subscriptionBalanceViewModel.errorFetchingSubscriptionBalance",
	)
}
