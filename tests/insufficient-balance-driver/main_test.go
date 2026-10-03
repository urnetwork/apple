// SPDX-License-Identifier: MPL-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeSystem records commands and plays a scripted UI test. No process,
// network, Xcode or clock is used: Sleep advances the fake clock and lets the
// scripted UI test answer the pending request.
type fakeSystem struct {
	t        *testing.T
	now      time.Time
	commands []string
	// responses by command prefix
	outputs map[string]string
	fails   map[string]error
	fetches map[string]fakeFetch
	alive   map[int]bool
	started []string
	signals []string
	// answers a request file in the channel; nil leaves it unanswered
	ui      func(seq int, verb, arg string) (result any, err string)
	channel string
	// called on every Run of `scutil --nc list`
	scutilLists []string
}

type fakeFetch struct {
	body string
	n    int64
	err  error
}

func newFakeSystem(t *testing.T) *fakeSystem {
	return &fakeSystem{
		t:       t,
		now:     time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC),
		outputs: map[string]string{},
		fails:   map[string]error{},
		fetches: map[string]fakeFetch{},
		alive:   map[int]bool{},
	}
}

func (self *fakeSystem) Run(ctx context.Context, logPath string, name string, args ...string) ([]byte, error) {
	command := strings.Join(append([]string{filepath.Base(name)}, args...), " ")
	self.commands = append(self.commands, command)
	for prefix, err := range self.fails {
		if strings.HasPrefix(command, prefix) {
			return nil, err
		}
	}
	if command == "scutil --nc list" && 0 < len(self.scutilLists) {
		out := self.scutilLists[0]
		if 1 < len(self.scutilLists) {
			self.scutilLists = self.scutilLists[1:]
		}
		return []byte(out), nil
	}
	for prefix, out := range self.outputs {
		if strings.HasPrefix(command, prefix) {
			return []byte(out), nil
		}
	}
	return nil, nil
}

func (self *fakeSystem) Start(logPath string, name string, args ...string) (int, error) {
	self.started = append(self.started, strings.Join(append([]string{name}, args...), " "))
	self.alive[4242] = true
	return 4242, nil
}

func (self *fakeSystem) Alive(pid int) bool { return self.alive[pid] }

func (self *fakeSystem) SignalGroup(pid int, sig syscall.Signal) error {
	self.signals = append(self.signals, fmt.Sprintf("%d %v", pid, sig))
	if sig == syscall.SIGTERM {
		self.alive[pid] = false
	}
	return nil
}

func (self *fakeSystem) Fetch(ctx context.Context, url string, timeout time.Duration, keep int64) ([]byte, int64, error) {
	f, ok := self.fetches[url]
	if !ok {
		return nil, 0, errors.New("dial tcp: i/o timeout")
	}
	return []byte(f.body), f.n, f.err
}

func (self *fakeSystem) Now() time.Time { return self.now }

func (self *fakeSystem) Sleep(ctx context.Context, d time.Duration) error {
	self.now = self.now.Add(d)
	self.answer()
	return nil
}

// answer plays the UI test for every unanswered request.
func (self *fakeSystem) answer() {
	if self.ui == nil || self.channel == "" {
		return
	}
	paths, _ := filepath.Glob(filepath.Join(self.channel, "request-*.json"))
	for _, path := range paths {
		var request struct {
			Seq  int    `json:"seq"`
			Verb string `json:"verb"`
			Arg  string `json:"arg"`
		}
		b, err := os.ReadFile(path)
		if err != nil || json.Unmarshal(b, &request) != nil {
			self.t.Fatalf("unreadable request %s", path)
		}
		replyPath := filepath.Join(self.channel, fmt.Sprintf("reply-%d.json", request.Seq))
		if _, err := os.Stat(replyPath); err == nil {
			continue
		}
		result, failure := self.ui(request.Seq, request.Verb, request.Arg)
		if result == nil && failure == "" {
			continue
		}
		reply := map[string]any{"seq": request.Seq, "ok": failure == ""}
		if failure != "" {
			reply["error"] = failure
		} else {
			reply["result"] = result
		}
		b, _ = json.Marshal(reply)
		os.WriteFile(replyPath, b, 0600)
	}
}

func writeCredentials(t *testing.T, dir string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(dir, "credentials.yml")
	if err := os.WriteFile(path, []byte("email: ib@example.test\npassword: \"s3cret pass\"\n"), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

// newFixture lays out a workspace root with a fake SDK and build products.
func newFixture(t *testing.T) (*driver, *fakeSystem) {
	t.Helper()
	root := t.TempDir()
	state := filepath.Join(t.TempDir(), "apple")
	for _, dir := range []string{
		filepath.Join(root, "sdk", "build", "apple", "URnetworkSdk.xcframework"),
		filepath.Join(root, "apple", "tests", "__acceptance__", "build", "insufficient-balance-macos", "Build", "Products", "Debug", "URnetwork.app", "Contents", "PlugIns", "URnetwork.app"),
		state,
	} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	products := filepath.Join(root, "apple", "tests", "__acceptance__", "build", "insufficient-balance-macos", "Build", "Products")
	os.WriteFile(filepath.Join(products, "URnetworkUITests_macosx.xctestrun"), []byte("<plist/>"), 0600)
	os.WriteFile(filepath.Join(products, ".acceptance.xctestrun"), []byte("stale"), 0600)
	sys := newFakeSystem(t)
	d := &driver{
		sys:             sys,
		root:            root,
		state:           state,
		credentialsPath: writeCredentials(t, t.TempDir(), 0600),
	}
	sys.channel = d.channelDir()
	sys.outputs["PlistBuddy"] = "ib-20261002-120000\n"
	return d, sys
}

func runVerb(t *testing.T, d *driver, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := mainCode(context.Background(), d, args, &stdout, &stderr)
	return stdout.String(), stderr.String(), code
}

// exactly one JSON object and nothing else on stdout
func oneObject(t *testing.T, stdout string) map[string]any {
	t.Helper()
	var out map[string]any
	decoder := json.NewDecoder(strings.NewReader(stdout))
	if err := decoder.Decode(&out); err != nil {
		t.Fatalf("stdout is not one JSON object: %q", stdout)
	}
	if decoder.More() || strings.Count(stdout, "\n") != 1 {
		t.Fatalf("stdout carries more than one object: %q", stdout)
	}
	return out
}

func TestReadCredentialsUsesTheRunnerRules(t *testing.T) {
	dir := t.TempDir()
	email, password, err := readCredentials(writeCredentials(t, dir, 0600))
	if err != nil || email != "ib@example.test" || password != "s3cret pass" {
		t.Fatalf("got %q %q %v", email, password, err)
	}
	if _, _, err := readCredentials(writeCredentials(t, t.TempDir(), 0644)); err == nil {
		t.Fatal("a world-readable credentials file was accepted")
	}
	extra := filepath.Join(dir, "extra.yml")
	os.WriteFile(extra, []byte("email: a\npassword: b\ntoken: c\n"), 0600)
	if _, _, err := readCredentials(extra); err == nil {
		t.Fatal("an unknown key was accepted")
	}
	if _, _, err := readCredentials(""); err == nil {
		t.Fatal("a missing path was accepted")
	}
}

func TestEgressReturnsTheFirstValidAddress(t *testing.T) {
	d, sys := newFixture(t)
	sys.fetches[egressUrls[0]] = fakeFetch{body: "<html>captive</html>"}
	sys.fetches[egressUrls[1]] = fakeFetch{body: " 203.0.113.7\n"}
	stdout, _, code := runVerb(t, d, "egress")
	if code != 0 || oneObject(t, stdout)["ip"] != "203.0.113.7" {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
}

func TestHeldEgressIsAnErrorObjectNotAFailure(t *testing.T) {
	d, _ := newFixture(t)
	stdout, _, code := runVerb(t, d, "egress")
	out := oneObject(t, stdout)
	if code != 0 || out["ip"] != nil || !strings.Contains(out["error"].(string), "checkip.amazonaws.com") {
		t.Fatalf("a held probe must be {\"error\"} with exit 0: code=%d stdout=%q", code, stdout)
	}
}

func TestDirectEgressFailureExitsNonzero(t *testing.T) {
	d, _ := newFixture(t)
	stdout, stderr, code := runVerb(t, d, "direct-egress")
	if code == 0 || stdout != "" || strings.Count(stderr, "\n") != 1 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestTrafficNeverFailsWhileHeld(t *testing.T) {
	d, sys := newFixture(t)
	stdout, _, code := runVerb(t, d, "traffic")
	if code != 0 || oneObject(t, stdout)["bytes"] != float64(0) {
		t.Fatalf("held traffic: code=%d stdout=%q", code, stdout)
	}
	sys.fetches[trafficUrl] = fakeFetch{n: trafficByteCount}
	stdout, _, code = runVerb(t, d, "traffic")
	if code != 0 || oneObject(t, stdout)["bytes"] != float64(trafficByteCount) {
		t.Fatalf("open traffic: code=%d stdout=%q", code, stdout)
	}
}

func TestParseIpRejectsNonAddresses(t *testing.T) {
	for body, want := range map[string]string{"198.51.100.1\n": "198.51.100.1", "2001:db8::1": "2001:db8::1"} {
		if got, ok := parseIp([]byte(body)); !ok || got != want {
			t.Fatalf("%q: got %q %v", body, got, ok)
		}
	}
	for _, body := range []string{"", "blocked", "198.51.100.1 extra"} {
		if _, ok := parseIp([]byte(body)); ok {
			t.Fatalf("%q parsed as an address", body)
		}
	}
}

// setup builds with MAIN's macOS flags, passes credentials only through the
// private xctestrun, removes it, and returns the UI test's answer.
func TestSetupBuildsStartsTheUiTestAndRemovesTheCredentialCopy(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("setup refuses non-macOS hosts")
	}
	d, sys := newFixture(t)
	var setupRequests int
	sys.ui = func(seq int, verb, arg string) (any, string) {
		if verb != "setup" {
			t.Fatalf("unexpected verb %s", verb)
		}
		setupRequests += 1
		if _, err := os.Stat(d.xctestrunPath()); err != nil {
			t.Fatal("the UI test started without its private xctestrun")
		}
		return map[string]any{"kill_switch_supported": true}, ""
	}
	stdout, stderr, code := runVerb(t, d, "setup")
	if code != 0 {
		t.Fatalf("setup failed: %s", stderr)
	}
	if out := oneObject(t, stdout); out["kill_switch_supported"] != true || setupRequests != 1 {
		t.Fatalf("stdout=%q requests=%d", stdout, setupRequests)
	}
	if _, err := os.Stat(d.xctestrunPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the xctestrun with the password outlived setup")
	}
	all := strings.Join(sys.commands, "\n")
	for _, want := range []string{
		"bash -c source \"$1\"; apple_acceptance_macos_automation_ready",
		"xcodebuild build-for-testing",
		"-scheme URnetworkUITests -destination platform=macOS",
		"DEVELOPMENT_TEAM=6BGU69Q742 URNETWORK_ACCEPTANCE_BUILD_ID=ib-20261002-120000",
		"plutil -replace networkUITests.EnvironmentVariables.UR_ACCEPT_PASS -string s3cret pass",
		"plutil -replace networkUITests.EnvironmentVariables.UR_IB_CHANNEL -string " + d.channelDir(),
	} {
		if !strings.Contains(all, want) {
			t.Fatalf("missing command %q in:\n%s", want, all)
		}
	}
	if len(sys.started) != 1 || !strings.Contains(sys.started[0], "-only-testing:"+uiTestSelector) ||
		!strings.Contains(sys.started[0], "-xctestrun "+d.xctestrunPath()) {
		t.Fatalf("started %q", sys.started)
	}
	if strings.Contains(sys.started[0], ".acceptance.xctestrun") {
		t.Fatal("setup used MAIN's private xctestrun")
	}
}

func TestSetupRejectsAStaleApp(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("setup refuses non-macOS hosts")
	}
	d, sys := newFixture(t)
	sys.outputs["PlistBuddy"] = "20260901-000000-macos\n"
	_, stderr, code := runVerb(t, d, "setup")
	if code == 0 || !strings.Contains(stderr, "marker mismatch") || len(sys.started) != 0 {
		t.Fatalf("code=%d stderr=%q started=%v", code, stderr, sys.started)
	}
}

func TestFailureLineIsRedactedAndSingle(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("setup refuses non-macOS hosts")
	}
	d, sys := newFixture(t)
	sys.ui = func(seq int, verb, arg string) (any, string) {
		return nil, "login failed for ib@example.test with s3cret pass\nsecond line"
	}
	stdout, stderr, code := runVerb(t, d, "setup")
	if code == 0 || stdout != "" {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
	if strings.Contains(stderr, "ib@example.test") || strings.Contains(stderr, "s3cret") || strings.Count(stderr, "\n") != 1 {
		t.Fatalf("stderr leaks or is not one line: %q", stderr)
	}
}

func startedSession(t *testing.T, d *driver, sys *fakeSystem) {
	t.Helper()
	os.MkdirAll(d.serveDir(), 0700)
	os.MkdirAll(d.channelDir(), 0700)
	os.WriteFile(d.pidPath(), []byte("4242\n"), 0600)
	sys.alive[4242] = true
}

func TestObserveRelaysTheProtocolFields(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	sys.ui = func(seq int, verb, arg string) (any, string) {
		return map[string]any{
			"connect_requested":                  true,
			"connected":                          true,
			"insufficient_balance_alert":         true,
			"disconnect_visible":                 true,
			"upgrade_visible":                    true,
			"insufficient_balance_notifications": 1,
			"notification_marker_present":        true,
		}, ""
	}
	stdout, stderr, code := runVerb(t, d, "observe")
	out := oneObject(t, stdout)
	if code != 0 || out["insufficient_balance_notifications"] != float64(1) || out["disconnect_visible"] != true {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestObserveRejectsAnIncompleteReply(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	sys.ui = func(seq int, verb, arg string) (any, string) {
		return map[string]any{"connect_requested": true}, ""
	}
	if _, _, code := runVerb(t, d, "observe"); code == 0 {
		t.Fatal("an observation without every field was accepted")
	}
}

// Sequence numbers continue across verb processes, so a late reply to an
// earlier verb is never read as the answer to a later one.
func TestRequestsContinueTheSequenceAcrossVerbs(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	var seen []string
	sys.ui = func(seq int, verb, arg string) (any, string) {
		seen = append(seen, fmt.Sprintf("%d %s %s", seq, verb, arg))
		return map[string]any{}, ""
	}
	for _, args := range [][]string{{"connect"}, {"kill-switch", "on"}, {"press-disconnect"}} {
		if _, stderr, code := runVerb(t, d, args...); code != 0 {
			t.Fatalf("%v failed: %s", args, stderr)
		}
	}
	want := "1 connect |2 kill-switch on|3 press-disconnect "
	if got := strings.Join(seen, "|"); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestRequestFailsWhenTheUiTestEnds(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	os.WriteFile(d.testLogPath(), []byte("Test Case started\n/x/networkUITests.swift:12: error: -[networkUITests testInsufficientBalanceDriver] : missing UI control acceptance.connect\n** TEST FAILED **\n"), 0600)
	sys.ui = func(seq int, verb, arg string) (any, string) {
		sys.alive[4242] = false
		return nil, ""
	}
	_, stderr, code := runVerb(t, d, "connect")
	if code == 0 || !strings.Contains(stderr, "missing UI control acceptance.connect") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestRequestTimesOutWithoutAReply(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	sys.ui = func(seq int, verb, arg string) (any, string) { return nil, "" }
	_, stderr, code := runVerb(t, d, "press-disconnect")
	if code == 0 || !strings.Contains(stderr, "no reply within 1m0s") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestKillSwitchTakesOnlyOnOrOff(t *testing.T) {
	d, _ := newFixture(t)
	for _, args := range [][]string{{"kill-switch"}, {"kill-switch", "maybe"}, {"observe", "extra"}, {"bogus"}} {
		if _, _, code := runVerb(t, d, args...); code == 0 {
			t.Fatalf("%v was accepted", args)
		}
	}
}

func TestTeardownSignsOutStopsTheUiTestAndTheTunnel(t *testing.T) {
	d, sys := newFixture(t)
	startedSession(t, d, sys)
	os.WriteFile(d.xctestrunPath(), []byte("secret"), 0600)
	sys.ui = func(seq int, verb, arg string) (any, string) {
		if verb != "teardown" {
			t.Fatalf("unexpected verb %s", verb)
		}
		return map[string]any{}, ""
	}
	sys.scutilLists = []string{
		"Available network connection services in the current set (*=enabled):\n" +
			"* (Connected)      0A1B2C3D-0000-0000-0000-000000000001 VPN (network.ur.extension) \"URnetwork\"        [VPN/network.ur.extension]\n" +
			"* (Connected)      0A1B2C3D-0000-0000-0000-000000000002 VPN (com.example.other)    \"Other\"            [VPN/com.example.other]\n",
		"* (Disconnected)   0A1B2C3D-0000-0000-0000-000000000001 VPN (network.ur.extension) \"URnetwork\"        [VPN/network.ur.extension]\n",
	}
	stdout, stderr, code := runVerb(t, d, "teardown")
	if code != 0 || oneObject(t, stdout) == nil {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(d.channelDir(), "stop")); err != nil {
		t.Fatal("teardown did not stop the UI test loop")
	}
	if _, err := os.Stat(d.xctestrunPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("teardown left the private xctestrun")
	}
	all := strings.Join(sys.commands, "\n")
	if !strings.Contains(all, "osascript -e tell application id \"network.ur\" to quit") ||
		!strings.Contains(all, "scutil --nc stop 0A1B2C3D-0000-0000-0000-000000000001") ||
		strings.Contains(all, "000000000002") {
		t.Fatalf("commands:\n%s", all)
	}
	// the UI test never exited on its own in this fake, so it was signaled
	if len(sys.signals) == 0 || sys.signals[0] != "4242 terminated" {
		t.Fatalf("signals %v", sys.signals)
	}
}

func TestTeardownWithoutSetupIsQuietAndFailsOnALiveTunnel(t *testing.T) {
	d, sys := newFixture(t)
	stdout, _, code := runVerb(t, d, "teardown")
	if code != 0 || oneObject(t, stdout) == nil {
		t.Fatalf("teardown without setup failed: code=%d", code)
	}
	sys.scutilLists = []string{"* (Connected)  ID-1 VPN (network.ur.extension) \"URnetwork\" [VPN/network.ur.extension]\n"}
	if _, stderr, code := runVerb(t, d, "teardown"); code == 0 || !strings.Contains(stderr, "still active") {
		t.Fatalf("a tunnel that would not stop was accepted: code=%d stderr=%q", code, stderr)
	}
}

func TestActiveAppTunnelsIgnoresOtherAndDisconnectedServices(t *testing.T) {
	list := "Available network connection services in the current set (*=enabled):\n" +
		"* (Connecting)     ID-1 VPN (network.ur.extension) \"URnetwork\" [VPN/network.ur.extension]\n" +
		"* (Disconnected)   ID-2 VPN (network.ur.extension) \"URnetwork\" [VPN/network.ur.extension]\n" +
		"* (Connected)      ID-3 VPN (network.urx.extension) \"Lookalike\" [VPN/network.urx.extension]\n" +
		"* (Connected)      ID-4 PPP --> L2TP \"Office\" [PPP/L2TP]\n"
	if got := activeAppTunnels(list); len(got) != 1 || got[0] != "ID-1" {
		t.Fatalf("got %v", got)
	}
}

func TestLastFailureFindsTheXctestError(t *testing.T) {
	log := "a\n/x.swift:3: error: -[networkUITests test] : first\nb\n/x.swift:9: error: -[networkUITests test] : second\n** TEST FAILED **\n"
	if got := lastFailure(log); !strings.HasSuffix(got, "second") {
		t.Fatalf("got %q", got)
	}
	if lastFailure("all good\n") != "" {
		t.Fatal("a log without failures named one")
	}
}

func TestFindXctestrunIgnoresPrivateCopies(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".acceptance.xctestrun"), nil, 0600)
	if _, err := findXctestrun(dir); err == nil {
		t.Fatal("a private copy was used as Xcode's xctestrun")
	}
	os.WriteFile(filepath.Join(dir, "URnetworkUITests_macosx.xctestrun"), nil, 0600)
	if got, err := findXctestrun(dir); err != nil || filepath.Base(got) != "URnetworkUITests_macosx.xctestrun" {
		t.Fatalf("got %q %v", got, err)
	}
}
