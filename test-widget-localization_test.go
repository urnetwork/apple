package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Compile the actual SDK-free widget metadata with a Foundation-only fixture.
// This checks localization semantics, not iOS runtime or extension execution;
// the unchanged no-VPN simulator matrix supplies that integration proof.
func TestQuickConnectControlMetadata(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate Apple source")
	}
	root := filepath.Dir(source)
	controlPath := filepath.Join(root, "app/widgets/Control/QuickConnectControl.swift")
	control, err := os.ReadFile(controlPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range []string{
		".displayName(QuickConnectControlMetadata.displayName)",
		".description(QuickConnectControlMetadata.description)",
	} {
		if strings.Count(string(control), call) != 1 {
			t.Fatalf("control must consume the tested metadata exactly once: %s", call)
		}
	}
	tmp := t.TempDir()
	fixture := filepath.Join(tmp, "main.swift")
	if err := os.WriteFile(fixture, []byte(widgetMetadataFixture), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(name string, args ...string) []byte {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
		cmd.WaitDelay = 5 * time.Second
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("owned Foundation fixture failed: %v\n%s", err, out)
		}
		return out
	}
	binary := filepath.Join(tmp, "metadata-test")
	run("/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-j", "2", "-num-threads", "2",
		"-module-cache-path", filepath.Join(tmp, "module-cache"),
		filepath.Join(root, "app/widgets/Control/QuickConnectControlMetadata.swift"), fixture,
		"-o", binary)
	if out := run(binary); string(out) != "widget metadata: 12 semantic checks passed\n" {
		t.Fatalf("unexpected Foundation fixture result: %q", out)
	}
}

const widgetMetadataFixture = `import Foundation

func check(_ resource: LocalizedStringResource, expected: String) {
    precondition(resource.key == expected, "localization key changed")
    precondition(String(localized: resource.defaultValue) == expected, "fallback text changed")
    precondition(resource.table == nil, "default table changed")
    precondition(resource.locale == .current, "current locale changed")
    switch resource.bundle {
    case .main: break
    case .atURL(let url):
        precondition(url == Bundle.main.bundleURL, "resolved main bundle changed")
    default: preconditionFailure("default bundle changed")
    }
    precondition(String(localized: resource) == expected, "resource resolution changed")
}

check(QuickConnectControlMetadata.displayName, expected: "URnetwork")
check(QuickConnectControlMetadata.description, expected: "Connect or disconnect the URnetwork VPN.")
print("widget metadata: 12 semantic checks passed")
`
