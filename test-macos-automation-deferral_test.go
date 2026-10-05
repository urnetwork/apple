package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// These tests execute copied entry points in private fake workspaces. All
// platform commands are fakes; no test observes or changes a real TCC grant,
// simulator, application, account, or network route.
func macosAutomationSource(t *testing.T, relative string) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	return filepath.Join(filepath.Dir(source), relative)
}

func macosRead(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func macosWrite(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}

type macosAutomationFixture struct {
	t       *testing.T
	root    string
	env     map[string]string
	entry   string
	receipt string
}

func newMacosAutomationFixture(t *testing.T) *macosAutomationFixture {
	t.Helper()
	root := t.TempDir()
	f := &macosAutomationFixture{t: t, root: root, receipt: filepath.Join(root, "runner-coverage.json")}
	f.env = map[string]string{
		"PATH": filepath.Join(root, "bin") + string(os.PathListSeparator) + os.Getenv("PATH"),
		"HOME": os.Getenv("HOME"), "LC_ALL": "C", "GOMAXPROCS": "2",
		"TMPDIR": filepath.Join(root, "tmp"), "URNETWORK_ROOT": root,
		"URNETWORK_NETWORK_TEST_LOCK_HELD": "1", "TEST_TRACE": filepath.Join(root, "trace"),
		"UR_ACCEPT_VAULT":       filepath.Join(root, "vault/main/tests.yml"),
		"UR_ACCEPT_FIXTURE":     filepath.Join(root, "fixture.secret"),
		"UR_ACCEPT_RESULT_FILE": filepath.Join(root, "results.tsv"),
		"TEST_PROBE":            "listen=false post=false", "WARP_VERSION": "0.0.0-fixture",
		"URNETWORK_RUNNER_MACOS_AUTOMATION_COVERAGE_FILE": f.receipt,
		"URNETWORK_RUN_ID": "fixture-run", "URNETWORK_PLAN_SHA256": strings.Repeat("a", 64),
	}
	if err := os.MkdirAll(f.env["TMPDIR"], 0700); err != nil {
		t.Fatal(err)
	}
	macosWrite(t, f.env["UR_ACCEPT_VAULT"], "fixture only\n", 0600)
	f.script("tests/network-intensive-suite-lock.sh", `[ "$*" = "--verify-held main-acceptance" ]`)
	f.script("tests/read-tests-config.sh", `case "${1:-}" in --ready) exit 0 ;; get) printf 'fixture-value\n' ;; *) exit 2 ;; esac`)
	f.script("bin/timeout", `while [[ "${1:-}" == --* ]]; do shift; done; shift; exec "$@"`)
	f.script("bin/getconf", `printf '20\n'`)
	f.script("bin/go", `echo 'unexpected Go workload in fake workspace' >&2; exit 98`)
	f.script("bin/node", `
printf 'node:%s\n' "$(basename "$1")" >>"$TEST_TRACE"
case "$(basename "$1")" in
  preflight-main.mjs) exit 0 ;;
  client-cleanup.mjs|fixture.mjs)
    if [ "${TEST_EXISTING_RECEIPT:-0}" != 1 ] && [ -e "$URNETWORK_RUNNER_MACOS_AUTOMATION_COVERAGE_FILE" ]; then
      echo 'receipt published before cleanup completed' >&2; exit 91
    fi
    [ "${TEST_FAILURE:-}" != client-cleanup ] || exit 92
    ;;
  *) exit 93 ;;
esac`)
	f.script("bin/swift", `
[ "$1" = -e ] || exit 94
case "$2" in *CGPreflightListenEventAccess*CGPreflightPostEventAccess*) ;; *) exit 95 ;; esac
case "$2" in *CGRequest*) echo 'permission request is forbidden' >&2; exit 96 ;; esac
printf 'permission-probe\n' >>"$TEST_TRACE"
printf '%s\n' "$TEST_PROBE"
[ "${TEST_FAILURE:-}" != probe ]`)
	macosWrite(t, filepath.Join(root, "build/all/acceptance/preflight-main.mjs"), "fixture only\n", 0600)
	return f
}

func (f *macosAutomationFixture) script(relative, body string) {
	f.t.Helper()
	macosWrite(f.t, filepath.Join(f.root, relative), "#!/bin/bash\nset -euo pipefail\n"+body+"\n", 0700)
}

func (f *macosAutomationFixture) run(args ...string) (string, error) {
	f.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", append([]string{f.entry}, args...)...)
	cmd.Dir = f.root
	keys := make([]string, 0, len(f.env))
	for key := range f.env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		cmd.Env = append(cmd.Env, key+"="+f.env[key])
	}
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		f.t.Fatalf("fake harness timed out: %s", out)
	}
	return string(out), err
}

func (f *macosAutomationFixture) trace() string {
	f.t.Helper()
	data, err := os.ReadFile(f.env["TEST_TRACE"])
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		f.t.Fatal(err)
	}
	return string(data)
}

func (f *macosAutomationFixture) apple() {
	f.t.Helper()
	if runtime.GOOS != "darwin" {
		f.t.Skip("existing Apple entry point requires macOS plist tools")
	}
	for _, name := range []string{"test-main.sh", "test-main-lib.sh"} {
		macosWrite(f.t, filepath.Join(f.root, "apple", name), macosRead(f.t, macosAutomationSource(f.t, name)), 0700)
	}
	f.entry = filepath.Join(f.root, "apple/test-main.sh")
	f.env["URNETWORK_RUNNER_SUITE"] = "main"
	f.script("bin/xcrun", `
printf 'xcrun:%s\n' "$*" >>"$TEST_TRACE"
[ "$1" = simctl ] || exit 97
case "$2" in
  list)
    state=Shutdown
    [ ! -f "$URNETWORK_ROOT/booted" ] || state=Booted
    printf '    urnetwork-acceptance (SIMULATOR-FIXTURE) (%s)\n' "$state"
    ;;
  boot) touch "$URNETWORK_ROOT/booted" ;;
  shutdown)
    [ "${TEST_FAILURE:-}" != shutdown ] || exit 6
    rm -f "$URNETWORK_ROOT/booted"
    ;;
  pbpaste) printf '%s\n' 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour' ;;
  pbcopy) cat >/dev/null ;;
  bootstatus|terminate|uninstall|spawn|launch) ;;
  *) exit 98 ;;
esac`)
	f.script("bin/xcodebuild", `
printf 'xcodebuild:%s\n' "$*" >>"$TEST_TRACE"
[ "$1" = test-without-building ] || exit 97
case "$*" in *'platform=iOS Simulator,id=SIMULATOR-FIXTURE'*) ;; *) exit 98 ;; esac
[ ! -e "$URNETWORK_RUNNER_MACOS_AUTOMATION_COVERAGE_FILE" ] || [ "${TEST_EXISTING_RECEIPT:-0}" = 1 ] || exit 91
printf 'UR_ACCEPTANCE_CLIENT id=fixture-client\n'
[ "${TEST_FAILURE:-}" != ios ] || exit 6
if [ "${TEST_FAILURE:-}" != missing-pass ]; then
  for ((i=1; i<=${TEST_REPEAT:-1}; i++)); do printf 'UR_ACCEPTANCE_PASS repetition=%s platform=ios\n' "$i"; done
fi`)
	for _, name := range []string{"open", "osascript", "pbcopy", "pbpaste"} {
		f.script("bin/"+name, `printf '`+name+`:%s\n' "$*" >>"$TEST_TRACE"`)
	}
	f.script("bin/sleep", `exit 0`)
	f.script("bin/pgrep", `exit 0`)
	derived := filepath.Join(f.root, "apple/tests/__acceptance__/build/ios/Build/Products")
	macosWrite(f.t, filepath.Join(derived, "URnetwork.app/Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>URAcceptanceBuildID</key><string>fixture-build</string></dict></plist>`, 0600)
	macosWrite(f.t, filepath.Join(f.root, "apple/tests/__acceptance__/build/ios.build-id"), "fixture-build\n", 0600)
	var env strings.Builder
	for _, key := range []string{"USER", "PASS", "BUILD_ID", "PLATFORM", "REPEAT", "SIGNUP_NETWORK_PREFIX", "SIGNUP_PASSWORD", "SIGNUP_EMAIL_DOMAIN", "SIGNUP_EMAIL_PREFIX", "SIGNUP_PHONE", "SECRET"} {
		env.WriteString("<key>UR_ACCEPT_" + key + "</key><string></string>")
	}
	macosWrite(f.t, filepath.Join(derived, "fixture.xctestrun"), `<?xml version="1.0"?><plist version="1.0"><dict><key>networkUITests</key><dict><key>EnvironmentVariables</key><dict>`+env.String()+`</dict></dict></dict></plist>`, 0600)
	if err := os.MkdirAll(filepath.Join(f.root, "sdk/build/apple/URnetworkSdk.xcframework"), 0700); err != nil {
		f.t.Fatal(err)
	}
}

func (f *macosAutomationFixture) coverage() map[string]any {
	f.t.Helper()
	paths, err := filepath.Glob(filepath.Join(f.root, "apple/tests/__acceptance__/*/macos-automation-coverage.json"))
	if err != nil || len(paths) != 1 {
		f.t.Fatalf("want one local coverage artifact: %v %v", paths, err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(macosRead(f.t, paths[0])), &got); err != nil {
		f.t.Fatal(err)
	}
	return got
}

func TestMacOSAutomationProbeUsesReadOnlyExactBooleanProtocol(t *testing.T) {
	for _, probe := range []string{"listen=true post=true", "listen=false post=true", "listen=true post=false", "listen=false post=false", "", "listen=0 post=0", "listen=false post=false extra", "listen=false post=false\nnoise"} {
		t.Run(probe, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.env["TEST_PROBE"] = probe
			f.script("probe.sh", `source "$1"; apple_acceptance_macos_automation_probe`)
			f.entry = filepath.Join(f.root, "probe.sh")
			out, err := f.run(macosAutomationSource(t, "test-main-lib.sh"))
			valid := probe == "listen=true post=true" || probe == "listen=false post=true" || probe == "listen=true post=false" || probe == "listen=false post=false"
			if valid && (err != nil || out != probe+"\n") || !valid && err == nil {
				t.Fatalf("probe validity=%v err=%v output=%q", valid, err, out)
			}
		})
	}
}

func TestMacOSAutomationDeferralRunsIOSAndPublishesAfterCleanup(t *testing.T) {
	for _, probe := range []string{"listen=false post=false", "listen=false post=true", "listen=true post=false"} {
		t.Run(probe, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.apple()
			f.env["TEST_PROBE"] = probe
			f.env["TEST_REPEAT"] = "2"
			out, err := f.run("--defer-macos-ui-automation", "--repeat=2", "--skip-build", "--headless")
			if err != nil {
				t.Fatalf("selected iOS run failed: %v\n%s", err, out)
			}
			want := map[string]any{
				"version": float64(1), "run_id": "fixture-run", "plan_sha256": strings.Repeat("a", 64),
				"coverage_scope": "tailored-macos-ui-automation-deferred",
				"deferred":       []any{"apple/macos-ui-acceptance", "apple/macos-data-plane", "apple/macos-peer-to-peer"},
				"required":       []any{"apple/ios-ui-acceptance"}, "permission_probe": probe,
				"verdict": "PASS_TAILORED", "passed": true, "cleanup_complete": true,
			}
			var receipt map[string]any
			if err := json.Unmarshal([]byte(macosRead(t, f.receipt)), &receipt); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(receipt, want) || !reflect.DeepEqual(f.coverage(), want) {
				t.Fatalf("receipt/local coverage mismatch: got=%v want=%v", receipt, want)
			}
			trace := f.trace()
			for _, required := range []string{"xcodebuild:test-without-building", "node:client-cleanup.mjs", "node:fixture.mjs", "xcrun:simctl shutdown SIMULATOR-FIXTURE"} {
				if !strings.Contains(trace, required) {
					t.Fatalf("missing lifecycle work %q in %s", required, trace)
				}
			}
			for _, forbidden := range []string{"platform=macOS", "osascript:", "pbcopy:", "pbpaste:"} {
				if strings.Contains(trace, forbidden) {
					t.Fatalf("unexpected macOS automation %q in %s", forbidden, trace)
				}
			}
			matrix := macosRead(t, f.env["UR_ACCEPT_RESULT_FILE"])
			if strings.Count(matrix, "\tPASS\t") != 4 || strings.Count(matrix, "\tDEFERRED\t") != 2 || !strings.Contains(matrix, "apple\tdata-plane\tDEFERRED\t") || !strings.Contains(matrix, "apple\tpeer-to-peer\tDEFERRED\t") || !strings.Contains(out, "PASS_TAILORED") {
				t.Fatalf("wrong selected matrix/output: %s\n%s", matrix, out)
			}
			for _, path := range []string{filepath.Join(f.root, "booted"), f.env["UR_ACCEPT_FIXTURE"]} {
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatalf("owned resource remains: %s (%v)", path, err)
				}
			}
			entries, err := os.ReadDir(f.env["TMPDIR"])
			if err != nil || len(entries) != 0 {
				t.Fatalf("owned private credentials/cache remain: %v %v", entries, err)
			}
		})
	}
}

func TestMacOSAutomationDeferralRejectsInvalidProofAndFailures(t *testing.T) {
	for _, failure := range []string{"granted", "malformed", "probe", "ios", "missing-pass", "shutdown", "client-cleanup"} {
		t.Run(failure, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.apple()
			f.env["TEST_FAILURE"] = failure
			if failure == "granted" {
				f.env["TEST_PROBE"] = "listen=true post=true"
			} else if failure == "malformed" {
				f.env["TEST_PROBE"] = "unknown"
			}
			out, err := f.run("--defer-macos-ui-automation", "--skip-build", "--headless")
			if err == nil || strings.Contains(out, "PASS_TAILORED:") {
				t.Fatalf("failed permission/test/cleanup produced passing run: %v %s", err, out)
			}
			if _, err := os.Lstat(f.receipt); !os.IsNotExist(err) {
				t.Fatalf("failed run published a receipt: %v", err)
			}
			coverage := f.coverage()
			if coverage["passed"] != false || coverage["verdict"] != "FAIL" {
				t.Fatalf("failed local coverage claims success: %v", coverage)
			}
			if failure == "shutdown" && coverage["cleanup_complete"] != false {
				t.Fatalf("failed shutdown claimed successful cleanup: %v", coverage)
			}
			matrix := macosRead(t, f.env["UR_ACCEPT_RESULT_FILE"])
			if strings.Count(matrix, "\tFAIL\t") != 6 || strings.Contains(matrix, "\tDEFERRED\t") {
				t.Fatalf("failure escaped through deferral rows: %s", matrix)
			}
			if (failure == "granted" || failure == "malformed" || failure == "probe") && strings.Contains(f.trace(), "xcodebuild:") {
				t.Fatalf("invalid deferral proof reached iOS: %s", f.trace())
			}
		})
	}
}

func TestMacOSAutomationDeferralIsExplicitAndDoesNotReplaceReceipts(t *testing.T) {
	t.Run("environment does not enable deferral", func(t *testing.T) {
		f := newMacosAutomationFixture(t)
		f.apple()
		f.env["UR_ACCEPT_DEFER_MACOS_UI_AUTOMATION"] = "1"
		f.env["URNETWORK_DEFER_MACOS_UI_AUTOMATION"] = "1"
		if out, err := f.run("--skip-build"); err == nil || !strings.Contains(out, "macOS UI automation privacy grants are missing") {
			t.Fatalf("default full run inherited a deferral: %v %s", err, out)
		}
		if coverage := f.coverage(); coverage["coverage_scope"] != "full" || coverage["passed"] != false {
			t.Fatalf("default coverage changed: %v", coverage)
		}
	})
	t.Run("macos-only conflicts in either order", func(t *testing.T) {
		for _, args := range [][]string{{"--defer-macos-ui-automation", "--macos-only"}, {"--macos-only", "--ios-only", "--defer-macos-ui-automation"}} {
			f := newMacosAutomationFixture(t)
			f.apple()
			out, err := f.run(args...)
			if err == nil || !strings.Contains(out, "cannot be combined with --macos-only") || f.trace() != "" {
				t.Fatalf("conflicting selection reached work: %v %s %s", err, out, f.trace())
			}
		}
	})
	for _, kind := range []string{"regular", "symlink", "dangling-symlink"} {
		t.Run("receipt-"+kind, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.apple()
			f.env["TEST_EXISTING_RECEIPT"] = "1"
			const stale = "previous receipt must survive\n"
			foreign := filepath.Join(f.root, "foreign-receipt")
			if kind == "regular" {
				macosWrite(t, f.receipt, stale, 0600)
			} else {
				if kind == "symlink" {
					macosWrite(t, foreign, stale, 0600)
				}
				if err := os.Symlink(foreign, f.receipt); err != nil {
					t.Fatal(err)
				}
			}
			if out, err := f.run("--defer-macos-ui-automation", "--skip-build"); err == nil || !strings.Contains(out, "could not publish") {
				t.Fatalf("existing receipt accepted/replaced: %v %s", err, out)
			}
			if kind == "dangling-symlink" {
				if _, err := os.Stat(foreign); !os.IsNotExist(err) {
					t.Fatalf("dangling receipt target was created: %v", err)
				}
			} else if got := macosRead(t, f.receipt); got != stale {
				t.Fatalf("existing receipt overwritten: %s", got)
			}
			if f.coverage()["passed"] != false {
				t.Fatal("publication failure was absent from local coverage")
			}
		})
	}
	t.Run("standalone keeps local evidence only", func(t *testing.T) {
		f := newMacosAutomationFixture(t)
		f.apple()
		delete(f.env, "URNETWORK_RUNNER_SUITE")
		if out, err := f.run("--defer-macos-ui-automation", "--skip-build"); err != nil {
			t.Fatalf("standalone deferral failed: %v %s", err, out)
		}
		if f.coverage()["passed"] != true {
			t.Fatal("standalone local proof missing")
		}
		if _, err := os.Stat(f.receipt); !os.IsNotExist(err) {
			t.Fatalf("standalone run published runner evidence: %v", err)
		}
	})
}

func (f *macosAutomationFixture) rootHarness() {
	f.t.Helper()
	f.entry = filepath.Join(f.root, "tests/test-main.sh")
	macosWrite(f.t, f.entry, macosRead(f.t, macosAutomationSource(f.t, "../tests/test-main.sh")), 0700)
	f.script("tests/source-stability.sh", `printf 'fixture\tunchanged\tunchanged\n' >"$2"`)
	for _, platform := range []string{"android", "apple", "linux", "windows", "web"} {
		f.script("build/all/"+platform+"/setup.sh", `printf 'setup:`+platform+`:%s\n' "$*" >>"$TEST_TRACE"`)
	}
	for _, platform := range []string{"android", "apple", "linux", "windows", "mmm/ur.io", "server/proxy"} {
		f.script(platform+"/test-main.sh", `
platform="$(basename "$(dirname "$0")")"
[ "$platform" != proxy ] || platform=server/proxy
printf 'test:%s:%s\n' "$platform" "$*" >>"$TEST_TRACE"
defer=0
for arg in "$@"; do [ "$arg" != --defer-macos-ui-automation ] || defer=1; done
case "$platform" in
  android) cases='email phone instant password data-plane peer-to-peer usdc-quote' ;;
  apple) cases='email phone instant password data-plane peer-to-peer' ;;
  linux|windows) cases='email phone solana bittensor instant password data-plane peer-to-peer' ;;
  ur.io) cases='email phone google apple solana bittensor instant password data-plane extension usdc-quote usdc-pay chrome-desktop firefox-desktop chrome-phone webkit-phone webkit-tablet' ;;
  server/proxy) cases='socks http wireguard' ;;
esac
for case_name in $cases; do
  status=PASS; detail='mock result'
  if [ "$platform" = apple ] && { [ "$defer" = 1 ] || [ "${TEST_MATRIX_MODE:-}" = unauthorized ]; }; then
    case "$case_name" in
      data-plane|peer-to-peer) status=DEFERRED; detail='macOS UI automation permission denied (listen=false post=false); no native macOS tunnel coverage' ;;
      *) detail='iOS-only UI acceptance passed; macOS UI automation DEFERRED (listen=false post=false)' ;;
    esac
  fi
  case "${TEST_MATRIX_MODE:-}/$platform/$case_name" in
    missing/apple/data-plane) continue ;;
    skip/apple/data-plane) status=SKIP ;;
    fail/apple/data-plane) status=FAIL ;;
    false-pass/apple/data-plane) status=PASS ;;
    account-deferred/apple/email) status=DEFERRED ;;
    other-platform/linux/data-plane) status=DEFERRED ;;
    generic-account/apple/email) detail='mock result' ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$platform" "$case_name" "$status" "$detail" >>"$UR_ACCEPT_RESULT_FILE"
  if [ "${TEST_MATRIX_MODE:-}/$platform/$case_name" = duplicate/apple/data-plane ]; then
    printf '%s\t%s\t%s\t%s\n' "$platform" "$case_name" "$status" "$detail" >>"$UR_ACCEPT_RESULT_FILE"
  fi
done
case "$platform" in android|apple|linux)
  printf '%s\n' 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour' >"$UR_ACCEPT_FIXTURE"
  ;; windows) rm -f "$UR_ACCEPT_FIXTURE" ;; esac`)
	}
	f.script("apple/test-hardware-startup.sh", `
printf 'test:apple-startup:%s\n' "$*" >>"$TEST_TRACE"
printf 'apple\thardware-startup-no-vpn\tPASS\tselected startup matrix passed\n' >>"$UR_ACCEPT_RESULT_FILE"`)
}

func TestRootMacOSAutomationDeferralPreservesSelectedMatrix(t *testing.T) {
	for _, selection := range []string{"full", "macos", "combined"} {
		t.Run(selection, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.rootHarness()
			args := []string{"--headless", "--no-sudo", "--compact-output", "--skip-payments"}
			if selection != "full" {
				args = append(args, "--defer-macos-ui-automation")
			} else {
				f.env["UR_ACCEPT_DEFER_MACOS_UI_AUTOMATION"] = "1"
			}
			if selection == "combined" {
				args = append(args, "--defer-ios-17-2")
			}
			out, err := f.run(args...)
			if err != nil {
				t.Fatalf("selected root matrix failed: %v\n%s", err, out)
			}
			trace := f.trace()
			if strings.Count(trace, "setup:") != 5 || strings.Count(trace, "test:") != 7 {
				t.Fatalf("platform/setup/startup coverage narrowed: %s", trace)
			}
			wantDeferred := 0
			if selection != "full" {
				wantDeferred = 1
				if !strings.Contains(out, "PASS_TAILORED: selected acceptance matrix passed;") || !strings.Contains(out, "native macOS data-plane, and peer-to-peer DEFERRED, not full MAIN coverage") || strings.Contains(out, "all acceptance suites passed") {
					t.Fatalf("tailored matrix claimed full coverage: %s", out)
				}
			} else if strings.Contains(out, "PASS_TAILORED") || !strings.Contains(out, "all acceptance suites passed") {
				t.Fatalf("default result changed: %s", out)
			}
			if strings.Count(trace, "--defer-macos-ui-automation") != wantDeferred {
				t.Fatalf("deferral was not passed only to Apple UI owner: %s", trace)
			}
			startup := "test:apple-startup:"
			if selection == "combined" {
				startup += "--defer-ios-17-2"
				if !strings.Contains(out, "iOS 17.2 and macOS UI") || strings.Count(trace, "--defer-ios-17-2") != 1 {
					t.Fatalf("combined omissions were not explicit: %s\n%s", trace, out)
				}
			}
			if !strings.Contains(trace, startup+"\n") {
				t.Fatalf("iOS startup selection changed: %s", trace)
			}
		})
	}
}

func TestRootMacOSAutomationDeferralRejectsBroaderOmissions(t *testing.T) {
	for _, mode := range []string{"missing", "skip", "fail", "false-pass", "account-deferred", "other-platform", "generic-account", "duplicate", "unauthorized"} {
		t.Run(mode, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.rootHarness()
			f.env["TEST_MATRIX_MODE"] = mode
			args := []string{"--headless", "--no-sudo", "--compact-output", "--skip-payments"}
			if mode != "unauthorized" {
				args = append(args, "--defer-macos-ui-automation")
			}
			if out, err := f.run(args...); err == nil || strings.Contains(out, "PASS_TAILORED: selected acceptance matrix passed;") || strings.Contains(out, "all acceptance suites passed") {
				t.Fatalf("invalid matrix accepted: %v %s", err, out)
			}
		})
	}
	for _, option := range []string{"--skip-apple", "--skip-ios-hardware", "--macos-only", "UR_ACCEPT_SKIP_APPLE", "UR_ACCEPT_SKIP_IOS_HARDWARE"} {
		t.Run(option, func(t *testing.T) {
			f := newMacosAutomationFixture(t)
			f.rootHarness()
			args := []string{"--defer-macos-ui-automation"}
			if strings.HasPrefix(option, "--") {
				args = append(args, option)
			} else {
				f.env[option] = "1"
			}
			if out, err := f.run(args...); err == nil || f.trace() != "" {
				t.Fatalf("conflicting flags reached platform work: %v %s %s", err, out, f.trace())
			}
		})
	}
}
