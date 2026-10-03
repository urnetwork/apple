// SPDX-License-Identifier: MPL-2.0

// The apple insufficient-balance driver for MAIN (tests/runner/RUN-MAIN.md,
// "Driver protocol"). It owns the native macOS lane: the same signed
// URnetworkUITests build and XCUITest helpers as apple/test-main.sh, with one
// long-lived UI test (networkUITests.testInsufficientBalanceDriver) that keeps
// the launched app between verbs. Each verb is one process that prints one
// JSON object; UI verbs are relayed to the UI test through request/reply files
// in the private state directory. Egress and traffic probes run here, a
// process outside the app, so they take the system path the tunnel holds.
//
// The iOS simulator refuses NetworkExtension and physical iOS is not a MAIN
// tunnel lane, so macOS is the only Apple lane with a real tunnel.
//
// Credentials reach the UI test the way MAIN passes them: in a private
// xctestrun copy that is deleted as soon as the test has started. Values are
// never printed; error lines are redacted.
//
// Standard library only: apple/test-insufficient-balance-driver builds it into
// the state directory.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	appBundleId      = "network.ur"
	uiTestSelector   = "networkUITests/networkUITests/testInsufficientBalanceDriver"
	trafficByteCount = 8 << 20
	pollInterval     = 200 * time.Millisecond
	// the runner allows 10 minutes per verb; leave room for cleanup
	verbBudget  = 9*time.Minute + 30*time.Second
	buildBudget = 7 * time.Minute
)

// Public address endpoints, in the order build/all/acceptance and the macOS
// UI acceptance use them.
var egressUrls = []string{
	"https://checkip.amazonaws.com/",
	"https://api.ipify.org/",
}

// Bounded download used to spend already-open contracts (as in the PERF
// payload fetch).
var trafficUrl = fmt.Sprintf("https://speed.cloudflare.com/__down?bytes=%d", trafficByteCount)

// ---- system boundary ----

// system is everything the driver does outside its own memory, so the verbs
// run deterministically against a fake.
type system interface {
	// Run waits for a command. With a log path its output goes there and the
	// returned output is empty; otherwise stdout is returned.
	Run(ctx context.Context, logPath string, name string, args ...string) ([]byte, error)
	// Start launches a detached command (own session, stdio to the log).
	Start(logPath string, name string, args ...string) (int, error)
	Alive(pid int) bool
	// SignalGroup signals the session started by Start.
	SignalGroup(pid int, sig syscall.Signal) error
	// Fetch makes one fresh request and returns up to keep bytes of the body
	// and the total body size read.
	Fetch(ctx context.Context, url string, timeout time.Duration, keep int64) ([]byte, int64, error)
	Now() time.Time
	Sleep(ctx context.Context, d time.Duration) error
}

type realSystem struct {
	stateLock sync.Mutex
	// processes started by this process; a zombie child still answers kill 0
	exitedPids map[int]bool
}

func newRealSystem() *realSystem {
	return &realSystem{exitedPids: map[int]bool{}}
}

func (self *realSystem) Run(ctx context.Context, logPath string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = 5 * time.Second
	if logPath == "" {
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			return out, fmt.Errorf("%s: %w: %s", filepath.Base(name), err, lastLine(stderr.String()))
		}
		return out, nil
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s: %w (see %s)", filepath.Base(name), err, logPath)
	}
	return nil, nil
}

func (self *realSystem) Start(logPath string, name string, args ...string) (int, error) {
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return 0, err
	}
	defer log.Close()
	cmd := exec.Command(name, args...)
	// stdio must not be the runner's pipes, or the runner waits on this
	// process after the verb exits
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, log, log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	pid := cmd.Process.Pid
	go func() {
		cmd.Wait()
		self.stateLock.Lock()
		defer self.stateLock.Unlock()
		self.exitedPids[pid] = true
	}()
	return pid, nil
}

func (self *realSystem) Alive(pid int) bool {
	self.stateLock.Lock()
	exited := self.exitedPids[pid]
	self.stateLock.Unlock()
	return 0 < pid && !exited && syscall.Kill(pid, 0) == nil
}

func (self *realSystem) SignalGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(-pid, sig)
}

func (self *realSystem) Fetch(ctx context.Context, url string, timeout time.Duration, keep int64) ([]byte, int64, error) {
	// a fresh connection per probe: a pooled connection from before the
	// tunnel would bypass the path under test
	client := &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DisableKeepAlives: true, Proxy: nil},
	}
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, 0, err
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer res.Body.Close()
	var kept bytes.Buffer
	n, err := io.Copy(io.MultiWriter(&limitedWriter{w: &kept, n: keep}, io.Discard), res.Body)
	if err != nil {
		return kept.Bytes(), n, err
	}
	if res.StatusCode != http.StatusOK {
		return kept.Bytes(), n, fmt.Errorf("HTTP %d", res.StatusCode)
	}
	return kept.Bytes(), n, nil
}

func (self *realSystem) Now() time.Time { return time.Now() }

func (self *realSystem) Sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

type limitedWriter struct {
	w io.Writer
	n int64
}

func (self *limitedWriter) Write(p []byte) (int, error) {
	if 0 < self.n {
		k := min(int64(len(p)), self.n)
		self.w.Write(p[:k])
		self.n -= k
	}
	return len(p), nil
}

// ---- driver ----

type driver struct {
	sys             system
	root            string
	state           string
	credentialsPath string
	// set once credentials are read, for redaction
	secrets []string
}

func (self *driver) appDir() string { return filepath.Join(self.root, "apple") }
func (self *driver) derivedDir() string {
	return filepath.Join(self.appDir(), "tests", "__acceptance__", "build", "insufficient-balance-macos")
}
func (self *driver) serveDir() string   { return filepath.Join(self.state, "serve") }
func (self *driver) channelDir() string { return filepath.Join(self.state, "channel") }
func (self *driver) pidPath() string    { return filepath.Join(self.serveDir(), "pid") }
func (self *driver) testLogPath() string {
	return filepath.Join(self.serveDir(), "test.log")
}
func (self *driver) xctestrunPath() string {
	return filepath.Join(self.serveDir(), "driver.xctestrun")
}

// run dispatches one verb and returns the JSON object to print.
func (self *driver) run(ctx context.Context, args []string) (any, error) {
	if len(args) == 0 {
		return nil, errors.New("missing verb")
	}
	verb, rest := args[0], args[1:]
	wantArgs := 0
	if verb == "kill-switch" {
		wantArgs = 1
	}
	if len(rest) != wantArgs {
		return nil, fmt.Errorf("%s: unexpected arguments", verb)
	}
	switch verb {
	case "setup":
		return self.setup(ctx)
	case "direct-egress":
		ip, err := self.probeEgress(ctx)
		if err != nil {
			return nil, fmt.Errorf("direct egress: %w", err)
		}
		return egressResult{Ip: ip}, nil
	case "connect":
		return struct{}{}, self.request(ctx, "connect", "", 4*time.Minute, nil)
	case "observe":
		return self.observe(ctx)
	case "egress":
		ip, err := self.probeEgress(ctx)
		if err != nil {
			// a failed probe is held traffic, not a driver failure
			return egressResult{Error: err.Error()}, nil
		}
		return egressResult{Ip: ip}, nil
	case "traffic":
		return self.traffic(ctx), nil
	case "press-disconnect":
		return struct{}{}, self.request(ctx, "press-disconnect", "", time.Minute, nil)
	case "kill-switch":
		if rest[0] != "on" && rest[0] != "off" {
			return nil, errors.New("kill-switch takes on or off")
		}
		return struct{}{}, self.request(ctx, "kill-switch", rest[0], 3*time.Minute, nil)
	case "teardown":
		return struct{}{}, self.teardown(ctx)
	}
	return nil, fmt.Errorf("unknown verb %q", verb)
}

type egressResult struct {
	Ip    string `json:"ip,omitempty"`
	Error string `json:"error,omitempty"`
}

type setupResult struct {
	KillSwitchSupported bool `json:"kill_switch_supported"`
}

// setup builds the current tree, starts the UI test, and signs in.
func (self *driver) setup(ctx context.Context) (any, error) {
	email, password, err := readCredentials(self.credentialsPath)
	if err != nil {
		return nil, err
	}
	self.secrets = []string{email, password}
	if runtime.GOOS != "darwin" {
		return nil, errors.New("the apple driver runs on the macOS acceptance host")
	}
	if pid, ok := self.servePid(); ok && self.sys.Alive(pid) {
		return nil, errors.New("a previous driver session is still running; run teardown first")
	}
	if _, err := self.sys.Run(ctx, "", "/bin/bash", "-c",
		`source "$1"; apple_acceptance_macos_automation_ready`, "driver",
		filepath.Join(self.appDir(), "test-main-lib.sh")); err != nil {
		return nil, fmt.Errorf("macOS UI automation privacy grants are missing: %w", err)
	}
	if info, err := os.Stat(filepath.Join(self.root, "sdk", "build", "apple", "URnetworkSdk.xcframework")); err != nil || !info.IsDir() {
		return nil, errors.New("the local Apple SDK is missing; MAIN's apple/test-main.sh builds it")
	}
	for _, dir := range []string{self.serveDir(), self.channelDir()} {
		if err := os.RemoveAll(dir); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
	}

	buildId := "ib-" + self.sys.Now().UTC().Format("20060102-150405")
	derived := self.derivedDir()
	buildCtx, cancel := context.WithTimeout(ctx, buildBudget)
	_, err = self.sys.Run(buildCtx, filepath.Join(self.state, "build.log"), "xcodebuild",
		"build-for-testing",
		"-project", filepath.Join(self.appDir(), "app", "app.xcodeproj"),
		"-scheme", "URnetworkUITests",
		"-destination", "platform=macOS",
		"-derivedDataPath", derived,
		"-configuration", "Debug",
		"-allowProvisioningUpdates",
		"DEVELOPMENT_TEAM=6BGU69Q742",
		"URNETWORK_ACCEPTANCE_BUILD_ID="+buildId,
	)
	cancel()
	if err != nil {
		return nil, fmt.Errorf("build the macOS acceptance app: %w", err)
	}
	products := filepath.Join(derived, "Build", "Products")
	appPath, err := findApp(products)
	if err != nil {
		return nil, err
	}
	marker, err := self.sys.Run(ctx, "", "/usr/libexec/PlistBuddy", "-c", "Print :URAcceptanceBuildID", filepath.Join(appPath, "Contents", "Info.plist"))
	if err != nil || strings.TrimSpace(string(marker)) != buildId {
		return nil, fmt.Errorf("built app marker mismatch: expected %s", buildId)
	}

	source, err := findXctestrun(products)
	if err != nil {
		return nil, err
	}
	xctestrun := self.xctestrunPath()
	// the copy carries the password: remove it on every path once the UI
	// test has read it
	defer os.Remove(xctestrun)
	if err := copyPrivate(source, xctestrun); err != nil {
		return nil, err
	}
	for _, kv := range [][2]string{
		{"UR_ACCEPT_USER", email},
		{"UR_ACCEPT_PASS", password},
		{"UR_ACCEPT_BUILD_ID", buildId},
		{"UR_ACCEPT_PLATFORM", "macos"},
		{"UR_IB_CHANNEL", self.channelDir()},
	} {
		if _, err := self.sys.Run(ctx, "", "/usr/bin/plutil", "-replace",
			"networkUITests.EnvironmentVariables."+kv[0], "-string", kv[1], xctestrun); err != nil {
			return nil, fmt.Errorf("prepare the private xctestrun for %s", kv[0])
		}
	}

	pid, err := self.sys.Start(self.testLogPath(), "xcodebuild",
		"test-without-building",
		"-xctestrun", xctestrun,
		"-destination", "platform=macOS",
		"-derivedDataPath", derived,
		"-only-testing:"+uiTestSelector,
		"-resultBundlePath", filepath.Join(self.serveDir(), "result.xcresult"),
	)
	if err != nil {
		return nil, fmt.Errorf("start the UI driver test: %w", err)
	}
	if err := os.WriteFile(self.pidPath(), []byte(strconv.Itoa(pid)+"\n"), 0600); err != nil {
		return nil, err
	}
	var out setupResult
	if err := self.request(ctx, "setup", "", verbBudget-buildBudget, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// observation is the protocol's observe object. Pointers detect a reply that
// omits a field.
type observation struct {
	ConnectRequested *bool `json:"connect_requested"`
	Connected        *bool `json:"connected"`
	Alert            *bool `json:"insufficient_balance_alert"`
	DisconnectButton *bool `json:"disconnect_visible"`
	UpgradeButton    *bool `json:"upgrade_visible"`
	Notifications    *int  `json:"insufficient_balance_notifications"`
	// diagnostic: false on a build without the post-count marker
	NotificationMarker *bool `json:"notification_marker_present,omitempty"`
}

func (self *driver) observe(ctx context.Context) (any, error) {
	var out observation
	if err := self.request(ctx, "observe", "", time.Minute, &out); err != nil {
		return nil, err
	}
	if err := validObservation(out); err != nil {
		return nil, err
	}
	return out, nil
}

func validObservation(o observation) error {
	if o.ConnectRequested == nil || o.Connected == nil || o.Alert == nil ||
		o.DisconnectButton == nil || o.UpgradeButton == nil || o.Notifications == nil {
		return errors.New("observe: the UI test omitted a field")
	}
	if *o.Notifications < 0 {
		return errors.New("observe: negative notification count")
	}
	return nil
}

// probeEgress returns the public address a non-app process sees now.
func (self *driver) probeEgress(ctx context.Context) (string, error) {
	var errs []string
	for _, url := range egressUrls {
		body, _, err := self.sys.Fetch(ctx, url, 15*time.Second, 256)
		if err == nil {
			if ip, ok := parseIp(body); ok {
				return ip, nil
			}
			err = errors.New("not an address")
		}
		errs = append(errs, fmt.Sprintf("%s: %v", hostOf(url), err))
	}
	return "", errors.New(strings.Join(errs, "; "))
}

type trafficResult struct {
	ByteCount int64 `json:"bytes"`
}

// traffic downloads a bounded body. Failure is expected while traffic is
// held, so it is reported as zero bytes, never as a verb failure.
func (self *driver) traffic(ctx context.Context) trafficResult {
	_, n, _ := self.sys.Fetch(ctx, trafficUrl, time.Minute, 0)
	return trafficResult{ByteCount: n}
}

// teardown signs out through the UI when the UI test is still running, stops
// it, quits the app, and stops any URnetwork tunnel the UI could not.
func (self *driver) teardown(ctx context.Context) error {
	var errs []error
	if email, password, err := readCredentials(self.credentialsPath); err == nil {
		self.secrets = []string{email, password}
	}
	if pid, ok := self.servePid(); ok {
		if self.sys.Alive(pid) {
			if err := self.request(ctx, "teardown", "", 4*time.Minute, nil); err != nil {
				errs = append(errs, fmt.Errorf("sign out through the UI: %w", err))
			}
			os.WriteFile(filepath.Join(self.channelDir(), "stop"), nil, 0600)
			if !self.waitExit(ctx, pid, time.Minute) {
				self.sys.SignalGroup(pid, syscall.SIGTERM)
				if !self.waitExit(ctx, pid, 10*time.Second) {
					self.sys.SignalGroup(pid, syscall.SIGKILL)
					if !self.waitExit(ctx, pid, 10*time.Second) {
						errs = append(errs, errors.New("the UI driver test survived SIGKILL"))
					}
				}
			}
		}
		os.Remove(self.pidPath())
	}
	os.Remove(self.xctestrunPath())
	// as apple/test-main.sh cleanup
	self.sys.Run(ctx, "", "/usr/bin/osascript", "-e", `tell application id "`+appBundleId+`" to quit`)
	if err := self.stopTunnels(ctx); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

func (self *driver) waitExit(ctx context.Context, pid int, limit time.Duration) bool {
	deadline := self.sys.Now().Add(limit)
	for self.sys.Alive(pid) {
		if !self.sys.Now().Before(deadline) || self.sys.Sleep(ctx, pollInterval) != nil {
			return !self.sys.Alive(pid)
		}
	}
	return true
}

// stopTunnels stops URnetwork VPN services the UI left up, then requires
// none to remain active.
func (self *driver) stopTunnels(ctx context.Context) error {
	out, err := self.sys.Run(ctx, "", "/usr/sbin/scutil", "--nc", "list")
	if err != nil {
		return fmt.Errorf("list VPN services: %w", err)
	}
	active := activeAppTunnels(string(out))
	if len(active) == 0 {
		return nil
	}
	for _, id := range active {
		self.sys.Run(ctx, "", "/usr/sbin/scutil", "--nc", "stop", id)
	}
	deadline := self.sys.Now().Add(30 * time.Second)
	for {
		out, err := self.sys.Run(ctx, "", "/usr/sbin/scutil", "--nc", "list")
		if err == nil && len(activeAppTunnels(string(out))) == 0 {
			return nil
		}
		if !self.sys.Now().Before(deadline) || self.sys.Sleep(ctx, time.Second) != nil {
			return errors.New("a URnetwork tunnel is still active after teardown")
		}
	}
}

// activeAppTunnels parses `scutil --nc list` for URnetwork services that are
// not disconnected, e.g.
// `* (Connected)  0A1B-... VPN (network.ur.extension) "URnetwork"  [VPN/network.ur.extension]`.
func activeAppTunnels(list string) []string {
	var ids []string
	for _, line := range strings.Split(list, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 5 || (fields[0] != "*" && fields[0] != "-") || fields[3] != "VPN" {
			continue
		}
		status := strings.Trim(fields[1], "()")
		provider := strings.Trim(fields[4], "()")
		if provider != appBundleId && !strings.HasPrefix(provider, appBundleId+".") {
			continue
		}
		if status == "Disconnected" || status == "Invalid" {
			continue
		}
		ids = append(ids, fields[2])
	}
	return ids
}

// ---- UI test channel ----

type reply struct {
	Seq    int             `json:"seq"`
	Ok     bool            `json:"ok"`
	Error  string          `json:"error"`
	Result json.RawMessage `json:"result"`
}

func (self *driver) servePid() (int, bool) {
	b, err := os.ReadFile(self.pidPath())
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	return pid, err == nil && 0 < pid
}

// request sends one verb to the UI test and waits for its reply. Sequence
// numbers persist in the channel so every verb process continues the order.
func (self *driver) request(ctx context.Context, verb, arg string, limit time.Duration, out any) error {
	pid, ok := self.servePid()
	if !ok || !self.sys.Alive(pid) {
		return fmt.Errorf("%s: the UI driver test is not running%s", verb, self.testFailure())
	}
	seqPath := filepath.Join(self.channelDir(), "seq")
	seq := 1
	if b, err := os.ReadFile(seqPath); err == nil {
		last, err := strconv.Atoi(strings.TrimSpace(string(b)))
		if err != nil {
			return errors.New("corrupt channel sequence")
		}
		seq = last + 1
	}
	if err := os.WriteFile(seqPath, []byte(strconv.Itoa(seq)+"\n"), 0600); err != nil {
		return err
	}
	b, err := json.Marshal(map[string]any{"seq": seq, "verb": verb, "arg": arg})
	if err != nil {
		return err
	}
	requestPath := filepath.Join(self.channelDir(), fmt.Sprintf("request-%d.json", seq))
	if err := writeAtomic(requestPath, b); err != nil {
		return err
	}
	replyPath := filepath.Join(self.channelDir(), fmt.Sprintf("reply-%d.json", seq))
	deadline := self.sys.Now().Add(limit)
	for {
		if b, err := os.ReadFile(replyPath); err == nil {
			var r reply
			if err := json.Unmarshal(b, &r); err != nil || r.Seq != seq {
				return fmt.Errorf("%s: malformed reply", verb)
			}
			if !r.Ok {
				return fmt.Errorf("%s: %s", verb, bounded(r.Error, 200))
			}
			if out != nil {
				if len(r.Result) == 0 || json.Unmarshal(r.Result, out) != nil {
					return fmt.Errorf("%s: malformed result", verb)
				}
			}
			return nil
		}
		if !self.sys.Alive(pid) {
			return fmt.Errorf("%s: the UI driver test ended%s", verb, self.testFailure())
		}
		if !self.sys.Now().Before(deadline) {
			return fmt.Errorf("%s: no reply within %s", verb, limit)
		}
		if err := self.sys.Sleep(ctx, pollInterval); err != nil {
			return fmt.Errorf("%s: %w", verb, err)
		}
	}
}

// testFailure names the last XCTest failure in the UI test log, if any.
func (self *driver) testFailure() string {
	b, err := os.ReadFile(self.testLogPath())
	if err != nil {
		return ""
	}
	if line := lastFailure(string(b)); line != "" {
		return ": " + bounded(line, 200)
	}
	return ""
}

func lastFailure(log string) string {
	lines := strings.Split(log, "\n")
	for i := len(lines) - 1; 0 <= i; i -= 1 {
		line := strings.TrimSpace(lines[i])
		if strings.Contains(line, "error: -[") || strings.Contains(line, ": error:") || strings.HasPrefix(line, "Failing tests:") {
			return line
		}
	}
	return ""
}

// ---- helpers ----

// readCredentials reads the private `email:`/`password:` file with the
// runner's rules (tests/runner/balance). Values are never printed.
func readCredentials(path string) (email, password string, err error) {
	if path == "" {
		return "", "", errors.New("URNETWORK_INSUFFICIENT_BALANCE_CREDENTIALS is not set")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", "", errors.New("insufficient-balance credentials are unreadable")
	}
	if info.Mode().Perm()&0077 != 0 {
		return "", "", errors.New("insufficient-balance credentials must not be group/world readable")
	}
	f, err := os.Open(path)
	if err != nil {
		return "", "", errors.New("insufficient-balance credentials are unreadable")
	}
	defer f.Close()
	values := map[string]string{}
	s := bufio.NewScanner(io.LimitReader(f, 64<<10))
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		key = strings.TrimSpace(key)
		if !ok || (key != "email" && key != "password") || values[key] != "" {
			return "", "", errors.New("insufficient-balance credentials: only one email and one password key are allowed")
		}
		value = strings.TrimSpace(value)
		if 2 <= len(value) && (value[0] == '"' || value[0] == '\'') && value[len(value)-1] == value[0] {
			value = value[1 : len(value)-1]
		}
		values[key] = value
	}
	if err := s.Err(); err != nil {
		return "", "", err
	}
	if values["email"] == "" || values["password"] == "" {
		return "", "", errors.New("insufficient-balance credentials: email and password are required")
	}
	return values["email"], values["password"], nil
}

func parseIp(body []byte) (string, bool) {
	ip := net.ParseIP(strings.TrimSpace(string(body)))
	if ip == nil {
		return "", false
	}
	return ip.String(), true
}

func hostOf(url string) string {
	rest := strings.TrimPrefix(url, "https://")
	host, _, _ := strings.Cut(rest, "/")
	return host
}

// findApp returns the URnetwork.app product, never one nested in PlugIns.
func findApp(products string) (string, error) {
	var found []string
	filepath.WalkDir(products, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && d.Name() == "PlugIns" {
			return filepath.SkipDir
		}
		if d.IsDir() && d.Name() == "URnetwork.app" {
			found = append(found, path)
			return filepath.SkipDir
		}
		return nil
	})
	if len(found) == 0 {
		return "", errors.New("the macOS acceptance app is missing from the build products")
	}
	sort.Strings(found)
	return found[0], nil
}

// findXctestrun returns Xcode's xctestrun, never a private copy.
func findXctestrun(products string) (string, error) {
	entries, err := os.ReadDir(products)
	if err != nil {
		return "", errors.New("the build products are missing")
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".xctestrun") && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return "", errors.New("the xctestrun file is missing from the build products")
	}
	sort.Strings(names)
	return filepath.Join(products, names[0]), nil
}

func copyPrivate(source, destination string) error {
	b, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(destination, b, 0600)
}

func writeAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func bounded(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}

// redact removes credential values and keeps one line.
func redact(message string, secrets []string) string {
	for _, secret := range secrets {
		if secret != "" {
			message = strings.ReplaceAll(message, secret, "[redacted]")
		}
	}
	return strings.Join(strings.Fields(message), " ")
}

// mainCode prints exactly one JSON object on success, or one redacted stderr
// line and a nonzero code on failure.
func mainCode(ctx context.Context, d *driver, args []string, stdout, stderr io.Writer) int {
	verb := "driver"
	if 0 < len(args) {
		verb = args[0]
	}
	out, err := d.run(ctx, args)
	if err == nil {
		var b []byte
		b, err = json.Marshal(out)
		if err == nil {
			fmt.Fprintln(stdout, string(b))
			return 0
		}
	}
	fmt.Fprintln(stderr, redact(fmt.Sprintf("apple %s: %v", verb, err), d.secrets))
	return 1
}

func main() {
	d := &driver{
		sys:             newRealSystem(),
		root:            os.Getenv("URNETWORK_ROOT"),
		state:           os.Getenv("URNETWORK_INSUFFICIENT_BALANCE_STATE"),
		credentialsPath: os.Getenv("URNETWORK_INSUFFICIENT_BALANCE_CREDENTIALS"),
	}
	if !filepath.IsAbs(d.root) || !filepath.IsAbs(d.state) {
		fmt.Fprintln(os.Stderr, "apple driver: URNETWORK_ROOT and URNETWORK_INSUFFICIENT_BALANCE_STATE must be absolute")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), verbBudget)
	defer cancel()
	os.Exit(mainCode(ctx, d, os.Args[1:], os.Stdout, os.Stderr))
}
