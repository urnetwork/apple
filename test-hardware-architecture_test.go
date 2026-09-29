package main

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The existing platform fixture invokes a private copy of the real entry point
// with fake Xcode, SDK, lipo, and simctl commands. It never builds or uses a device.
func TestSimulatorArchitectureContract(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the platform fixture")
	}
	fixture := filepath.Join(filepath.Dir(source), "test-hardware-startup-runner.test.sh")
	for _, mode := range []string{
		"success", "deferred", "unsupported-host",
		"missing-app-slice", "missing-extension-slice",
		"wrong-app-slice", "wrong-extension-slice",
	} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "/bin/bash", fixture, mode)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
			cmd.WaitDelay = 5 * time.Second
			out, err := cmd.CombinedOutput()
			if err != nil || !strings.Contains(string(out), "apple simulator architecture fixture passed") {
				t.Fatalf("architecture contract: %v\n%s", err, out)
			}
		})
	}
}
