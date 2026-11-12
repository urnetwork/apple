package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// The Earnings session's owner is SwiftUI wiring the Swift unit tests cannot
// see, so these tests read it. The owner decided on 2026-11-12 to "make the
// session app-wide": one EarningsSession for the signed-in account, which
// every window and view shares, so on macOS a claim in flight in one window
// (File > New Window) shows in each, and Claim is held in each while any
// claim runs. The unit tests (SnLedgerTests) run the session, its owner
// EarningsSessions, and two windows' view models on it; these check that the
// app wires it so:
//   - the app makes the one owner, has it follow the device manager's
//     signed-in device whatever window is up, and hands it to every window;
//   - the main screens draw the signed-in device's session from it, and
//     neither the tab view (iOS) nor the split view (one per macOS window)
//     makes a session of its own;
//   - nothing else in the app makes a session but the view model's own for
//     previews and tests.

func earningsSessionRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func earningsSessionRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(earningsSessionRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

var earningsSessionBlockComment = regexp.MustCompile(`(?s)/\*.*?\*/`)

// The Swift without its comments: a name in a comment is not code.
func earningsSessionCode(source string) string {
	source = earningsSessionBlockComment.ReplaceAllString(source, "")
	var code strings.Builder
	for _, line := range strings.Split(source, "\n") {
		if at := strings.Index(line, "//"); at >= 0 {
			line = line[:at]
		}
		code.WriteString(line + "\n")
	}
	return code.String()
}

// The app owns the one session for the signed-in account and hands it to
// every window: it follows the device manager's device, a sign-in's device
// getting a fresh session and a sign-out ending it, and both platforms'
// window content gets the owner.
func TestEarningsSessionIsTheApps(t *testing.T) {
	app := earningsSessionCode(earningsSessionRead(t, "app/network/NetworkApp.swift"))
	for _, line := range []string{
		"@StateObject var earningsSessions: EarningsSessions",
		"let earningsSessions = EarningsSessions()",
		"_earningsSessions = StateObject(wrappedValue: earningsSessions)",
		"earningsSessions.follow(deviceManager.$device) {",
		"return EarningsSession(client: EarningsSdkClient(",
	} {
		if !strings.Contains(app, line) {
			t.Errorf("the app does not own the earnings session: %s", line)
		}
	}
	if got := strings.Count(app, ".environmentObject(earningsSessions)"); got != 2 {
		t.Errorf("%d window contents get the earnings session's owner, want 2 (iOS and macOS)", got)
	}
	// the init sets every stored property, the owner too, before its first
	// use of self (the delegate adaptor), or Swift refuses it
	owner, firstSelf := strings.Index(app, "_earningsSessions = StateObject(wrappedValue: earningsSessions)"), strings.Index(app, "appDelegate.deviceManager = deviceManager")
	if owner < 0 || firstSelf < 0 || firstSelf < owner {
		t.Error("the app's init uses self before it makes the earnings session's owner")
	}

	content := earningsSessionCode(earningsSessionRead(t, "app/network/ContentView.swift"))
	for _, line := range []string{
		"@EnvironmentObject var earningsSessions: EarningsSessions",
		"let earningsSession = earningsSessions.session(for: device),",
		"earningsSession: earningsSession,",
		// another device's session gets the main screens anew
		".id(ObjectIdentifier(earningsSession))",
	} {
		if !strings.Contains(content, line) {
			t.Errorf("the main screens do not draw the signed-in device's session: %s", line)
		}
	}
	main := earningsSessionCode(earningsSessionRead(t, "app/network/Main/MainView.swift"))
	if !strings.Contains(main, "let earningsSession: EarningsSession") {
		t.Error("the main view does not take the app's session")
	}
	if got := strings.Count(main, "earningsSession: earningsSession,"); got != 2 {
		t.Errorf("the main view hands the app's session to %d of the tab view and the split view, want 2", got)
	}
}

// Neither the tab view nor the split view, which each macOS window builds,
// makes a session: both take the app's and hand it to the Account screens.
func TestEarningsSessionIsNoWindowsOwn(t *testing.T) {
	for _, rel := range []string{
		"app/network/iOS/Navigation/MainTabView.swift",
		"app/network/mac0S/Navigation/MainNavigationSplitView.swift",
	} {
		view := earningsSessionCode(earningsSessionRead(t, rel))
		if !strings.Contains(view, "let earningsSession: EarningsSession") || !strings.Contains(view, "earningsSession: EarningsSession,") {
			t.Errorf("%s does not take the app's session", rel)
		}
		if !strings.Contains(view, "AccountNavStackView(") || !strings.Contains(view, "earningsSession: earningsSession,") {
			t.Errorf("%s does not hand the app's session to the Account screens", rel)
		}
		if strings.Contains(view, "EarningsSession(") || strings.Contains(view, "var earningsSession") {
			t.Errorf("%s makes or keeps a session of its own", rel)
		}
	}
}

// The app's owner makes every session the app draws; the view model's own,
// for previews and tests, is the only other.
func TestEarningsSessionIsMadeOnlyByTheApp(t *testing.T) {
	made := map[string]int{}
	owners := map[string]int{}
	err := filepath.Walk(filepath.Join(earningsSessionRoot(t), "app", "network"), func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".swift") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		code := earningsSessionCode(string(data))
		rel, _ := filepath.Rel(earningsSessionRoot(t), path)
		if n := strings.Count(code, "EarningsSession("); n > 0 {
			made[rel] = n
		}
		if n := strings.Count(code, "EarningsSessions("); n > 0 {
			owners[rel] = n
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{
		"app/network/NetworkApp.swift":                              1,
		"app/network/Main/Account/Earnings/EarningsViewModel.swift": 1,
	}
	if !earningsSessionSameCounts(made, want) {
		t.Errorf("sessions are made in %v, want %v", earningsSessionKeys(made), earningsSessionKeys(want))
	}
	if !earningsSessionSameCounts(owners, map[string]int{"app/network/NetworkApp.swift": 1}) {
		t.Errorf("the session's owner is made in %v, want the app alone", earningsSessionKeys(owners))
	}
	model := earningsSessionCode(earningsSessionRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift"))
	if !strings.Contains(model, "self.init(session: EarningsSession(client: client, sleep: sleep))") {
		t.Error("the view model's own session is not the convenience one for previews and tests")
	}
}

func earningsSessionSameCounts(got, want map[string]int) bool {
	if len(got) != len(want) {
		return false
	}
	for key, n := range want {
		if got[key] != n {
			return false
		}
	}
	return true
}

func earningsSessionKeys(counts map[string]int) []string {
	keys := []string{}
	for key, n := range counts {
		keys = append(keys, fmt.Sprintf("%s (%d)", key, n))
	}
	sort.Strings(keys)
	return keys
}
