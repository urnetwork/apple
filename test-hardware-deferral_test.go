package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Exercise the existing shell library using fixture files only. Never invoke
// Xcode, simctl, a device, or the real acceptance entry point.
func deferralShell(t *testing.T, script string, args ...string) ([]byte, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate fixture source")
	}
	lib := filepath.Join(filepath.Dir(source), "test-hardware-startup-lib.sh")
	argv := append([]string{"-c", `set -euo pipefail; source "$1"; shift; ` + script, "fixture", lib}, args...)
	return exec.CommandContext(ctx, "/bin/bash", argv...).CombinedOutput()
}

func TestIOS172DeferralSelectsOnlyRemainingReleases(t *testing.T) {
	got, err := deferralShell(t, "apple_ios_required_simulator_releases 1")
	want := "ios-18\t18\t18.5\nios-2026\t26\t26.5\nios-27\t27\t27.0\n"
	if err != nil || string(got) != want {
		t.Fatalf("explicit deferral did not preserve exactly the other three rows: err=%v output=%q", err, got)
	}
}

func deferralInventory(t *testing.T, versions ...string) string {
	t.Helper()
	items := []any{}
	for _, v := range versions {
		items = append(items, map[string]any{"platform": "iOS", "version": v, "buildversion": "fixture", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + strings.ReplaceAll(v, ".", "-"), "isAvailable": true, "supportedDeviceTypes": []any{map[string]string{"productFamily": "iPhone", "name": "iPhone Fixture", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Fixture"}}})
	}
	b, err := json.Marshal(map[string]any{"runtimes": items})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "runtimes.json")
	if err := os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestIOS172DeferralPlanProvisionAndDeploymentGuards(t *testing.T) {
	inventory := deferralInventory(t, "18.5", "26.5", "27.0")
	plan := filepath.Join(t.TempDir(), "plan.json")
	out, err := deferralShell(t, `apple_ios_write_simulator_runtime_plan "$1" "$2" 1
apple_ios_runtime_plan_supports_deployment_target "$2" 16 0 1
jq -r 'map(.identifier)|join(",")' "$2"
apple_ios_missing_simulator_downloads "$1" 1`, inventory, plan)
	if err != nil || string(out) != "ios-18,ios-2026,ios-27\n" {
		t.Fatalf("three-row plan: %v %s", err, out)
	}
	for _, script := range []string{
		`apple_ios_runtime_plan_supports_deployment_target "$2" 16 0`,
		`apple_ios_runtime_plan_supports_deployment_target "$2" 18 6 1`,
		`apple_ios_write_simulator_runtime_plan "$1" "$2.full"`,
		`apple_ios_required_simulator_releases 2`,
		`apple_ios_missing_simulator_downloads "$1" 18`,
		`apple_ios_write_simulator_runtime_plan "$1" "$2.invalid" 18`,
	} {
		if out, err := deferralShell(t, script, inventory, plan); err == nil {
			t.Fatalf("invalid/full policy accepted: %s (%s)", script, out)
		}
	}
	for _, missing := range []string{"18.5", "26.5", "27.0"} {
		t.Run(missing, func(t *testing.T) {
			versions := []string{}
			for _, v := range []string{"18.5", "26.5", "27.0"} {
				if v != missing {
					versions = append(versions, v)
				}
			}
			path := deferralInventory(t, versions...)
			out, err := deferralShell(t, `apple_ios_missing_simulator_downloads "$1" 1`, path)
			if err != nil || !strings.HasSuffix(string(out), "\t"+missing+"\n") || strings.Count(string(out), "\n") != 1 {
				t.Fatalf("wrong download: %s %v", out, err)
			}
			if out, err := deferralShell(t, `apple_ios_write_simulator_runtime_plan "$1" "$2" 1`, path, filepath.Join(t.TempDir(), "plan.json")); err == nil {
				t.Fatalf("missing other runtime passed: %s", out)
			}
		})
	}
	logs := t.TempDir()
	if out, err := deferralShell(t, `timeout() { echo "unexpected download" >&2; return 97; }; apple_ios_download_missing_simulator_runtimes "$1" "$2" default 1`, inventory, logs); err != nil {
		t.Fatalf("deferred 17.2 was downloaded: %v %s", err, out)
	}
	entries, err := os.ReadDir(logs)
	if err != nil || len(entries) != 0 {
		t.Fatalf("unexpected download artifacts: %v %v", entries, err)
	}
	for _, rewrite := range []string{`.[2].identifier="ios-17"`, `.[2].identifier="ios-18"`, `.[0:2]`} {
		bad := filepath.Join(t.TempDir(), "bad.json")
		if out, err := deferralShell(t, `jq "$3" "$1" > "$2"; apple_ios_runtime_plan_supports_deployment_target "$2" 16 0 1`, plan, bad, rewrite); err == nil {
			t.Fatalf("mutated exact matrix accepted: %s %s", rewrite, out)
		}
	}
}
