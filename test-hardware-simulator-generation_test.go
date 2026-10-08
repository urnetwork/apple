// SPDX-License-Identifier: MPL-2.0

// Drive the real startup entry point through synchronous command fixtures.
// Simulator generation ownership is observable at the installation boundary;
// the fixture retains an extension launch until its owner joins and deletes.
package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// These commands run only fake Apple tools. Cancellation kills their entire
// process group; WaitDelay alone can kill the leader and leave a child behind.
func configureSimulatorGenerationCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
}

// Run one isolated command-fixture mode, with a bounded process group lifetime.
func simulatorGenerationFixture(t *testing.T, mode string) {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate simulator generation fixture")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", filepath.Join(filepath.Dir(source), "test-hardware-startup-runner.test.sh"), mode)
	cmd.Env = append(os.Environ(), "TMPDIR="+t.TempDir())
	configureSimulatorGenerationCommand(cmd)
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "apple simulator architecture fixture passed") {
		t.Fatalf("simulator generation contract (%s): %v\n%s", mode, err, out)
	}
}

// A completed unit process does not join the old installation's widget work.
func TestSimulatorActionJoinsExtensionsBeforeUiInstallation(t *testing.T) {
	simulatorGenerationFixture(t, "extension-generation-unit-ui")
}

// The final UI action can leave the same pending work before another repeat.
func TestSimulatorRepetitionJoinsExtensionsBeforeUnitInstallation(t *testing.T) {
	simulatorGenerationFixture(t, "extension-generation-repetition")
}

// An owner that cannot be removed must stop the next action from installing.
func TestSimulatorCleanupFailureStopsFollowingInstallations(t *testing.T) {
	simulatorGenerationFixture(t, "extension-generation-cleanup-failure")
}

// Deletion and the next installation cannot substitute for a successful join.
func TestSimulatorShutdownFailureStopsFollowingInstallations(t *testing.T) {
	simulatorGenerationFixture(t, "extension-generation-shutdown-failure")
}

// Owner keys remain exact path components and cannot widen cleanup targets.
func TestSimulatorActionOwnerIdentityIsBounded(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate simulator generation library")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", "-c", `
set -euo pipefail
source "$1"
for owner in ios-17-unit-1 ios-18-ui-2 ios-2026-unit-10 ios-27-ui-1; do
  apple_ios_simulator_owner_is_valid "$owner"
  apple_ios_simulator_name_is_valid "$owner" "urnetwork-acceptance-$owner-20260101-120000Z"
done
for owner in ios-16-unit-1 ios-27-unit-0 ios-27-unit-01 ios-27-service-1 ios-27-unit-1/..; do
  if apple_ios_simulator_owner_is_valid "$owner"; then
    echo "invalid simulator owner accepted: $owner" >&2
    exit 1
  fi
done
if apple_ios_simulator_name_is_valid ios-27-unit-1 urnetwork-acceptance-ios-27-ui-1-20260101-120000Z; then
  echo "mismatched simulator action identity accepted" >&2
  exit 1
fi
`, "fixture", filepath.Join(filepath.Dir(source), "test-hardware-startup-lib.sh"))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("simulator owner validation: %v\n%s", err, out)
	}
}

// Readiness pipes force both TERM-ignoring members to be live before cancel.
// Both are direct children so the test can join them, with deadlines used only
// as failure backstops. The same kernel group signal covers shell descendants.
func TestSimulatorFixtureCancellationJoinsProcessGroup(t *testing.T) {
	start := func(ctx context.Context, groupId int) *exec.Cmd {
		t.Helper()
		readyRead, readyWrite, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer readyRead.Close()
		defer readyWrite.Close()
		inputRead, inputWrite, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer inputRead.Close()
		t.Cleanup(func() { _ = inputWrite.Close() })
		cmd := exec.CommandContext(ctx, "/bin/bash", "-c", `trap '' TERM; printf r >&3; read -r value`)
		cmd.Stdin = inputRead
		cmd.ExtraFiles = []*os.File{readyWrite}
		if groupId == 0 {
			configureSimulatorGenerationCommand(cmd)
		} else {
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: groupId}
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		})
		_ = readyWrite.Close()
		if _, err := io.ReadFull(readyRead, make([]byte, 1)); err != nil {
			t.Fatalf("fixture did not reach its cancellation barrier: %v", err)
		}
		return cmd
	}
	deadlineCtx, stop := context.WithTimeout(context.Background(), 10*time.Second)
	defer stop()
	ctx, cancel := context.WithCancel(deadlineCtx)
	defer cancel()
	leader := start(ctx, 0)
	member := start(deadlineCtx, leader.Process.Pid)
	cancel()
	for _, cmd := range []*exec.Cmd{leader, member} {
		err := cmd.Wait()
		exitError, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("group member did not terminate by signal: %v", err)
		}
		status, ok := exitError.Sys().(syscall.WaitStatus)
		if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
			t.Fatalf("group member survived the fixture cancellation signal: %v", err)
		}
	}
	if deadlineCtx.Err() != nil {
		t.Fatal("group member required the deadline backstop after fixture cancellation")
	}
}
