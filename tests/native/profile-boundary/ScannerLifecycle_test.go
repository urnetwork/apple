// Exercise the actual scanner's child ownership and the actual shell owner.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

var scannerTestRoot = flag.String("profile-source-root", "", "private actual-contract source copy")

// A FIFO makes readiness causal; the deadline is only a stuck-child backstop.
func scannerReadyPipe(t *testing.T, path string) *os.File {
	t.Helper()
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	// Darwin deliberately excludes FIFO files from Go deadline polling. A
	// joined watchdog writes an invalid PID only if real readiness gets stuck.
	finished := make(chan struct{})
	watchdog := time.AfterFunc(15*time.Second, func() {
		_, _ = file.Write([]byte("0 0 0\n"))
		close(finished)
	})
	t.Cleanup(func() {
		if !watchdog.Stop() {
			<-finished
		}
		file.Close()
	})
	return file
}

// The fake inventory process becomes sleep by exec, so the recorded PID is
// exactly the owned child, not a launcher with an unobserved descendant.
func scannerInventoryFixture(t *testing.T) (string, *os.File) {
	t.Helper()
	root := t.TempDir()
	readyPath := filepath.Join(root, "inventory-ready")
	ready := scannerReadyPipe(t, readyPath)
	script := "#!/bin/sh\nprintf '%s %s\\n' \"$$\" \"$PPID\" > \"$PROFILE_SCANNER_READY\"\nexec /bin/sleep 300\n"
	if err := os.WriteFile(filepath.Join(root, "rg"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", root+":"+os.Getenv("PATH"))
	t.Setenv("PROFILE_SCANNER_READY", readyPath)
	return root, ready
}

// Explicit cancellation must return only after the recorded rg process is
// reaped. No negative timeout or scheduling guess establishes this invariant.
func TestProfileScannerCancellationJoinsInventory(t *testing.T) {
	root, ready := scannerInventoryFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := profileScanInventory(ctx, root); done <- err }()
	var inventoryPid, parentPid int
	if _, err := fmt.Fscan(ready, &inventoryPid, &parentPid); err != nil || inventoryPid <= 0 || parentPid <= 0 {
		cancel()
		<-done
		t.Fatalf("inventory readiness failed: pid=%d parent=%d err=%v", inventoryPid, parentPid, err)
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("canceled inventory was accepted")
	}
	if err := syscall.Kill(inventoryPid, 0); err != syscall.ESRCH {
		t.Fatalf("inventory PID %d not reaped: %v", inventoryPid, err)
	}
	t.Logf("readiness PID=%d parent=%d; explicit cancellation joined inventory", inventoryPid, parentPid)
}

// Polling here only verifies OS cleanup after the explicit signal and Wait;
// process readiness and semantic assertions never depend on a quiet interval.
func scannerProcessesGone(t *testing.T, pids ...int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, pid := range pids {
		for syscall.Kill(pid, 0) != syscall.ESRCH {
			select {
			case <-ctx.Done():
				t.Fatalf("owned PID %d survived joined owner", pid)
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
}

// A real timeout owner is signaled only after the fake inventory has announced
// readiness. Its process group must contain go run, the compiled CLI and rg.
func TestProfileScannerOuterTerminationOwnsAllProcesses(t *testing.T) {
	if *scannerTestRoot == "" {
		t.Fatal("missing explicit private contract root")
	}
	timeoutPath, err := exec.LookPath("timeout")
	if err != nil {
		t.Fatal(err)
	}
	root, ready := scannerInventoryFixture(t)
	ownerPath := filepath.Join(root, "owner-ready")
	ownerReady := scannerReadyPipe(t, ownerPath)
	t.Setenv("PROFILE_SCANNER_OWNER_READY", ownerPath)
	script := "#!/bin/sh\nprintf '%s %s %s\\n' \"$$\" \"$1\" \"$2\" > \"$PROFILE_SCANNER_OWNER_READY\"\nexec " + strconv.Quote(timeoutPath) + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(root, "timeout"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/bash", "-c",
		`set -euo pipefail; source "$1"; apple_hardware_find_unguarded_profile_calls "$2/app/network" "$2/app/network/Shared/VPNProfileSystem.swift"`,
		"owned-profile-contract", filepath.Join(*scannerTestRoot, "test-hardware-startup-lib.sh"), *scannerTestRoot)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 2 * time.Second
	output, err := os.Create(filepath.Join(root, "owner-output.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	ownerPid, inventoryPid, scannerPid, goPid := 0, 0, 0, 0
	joined := false
	defer func() {
		// These exact PIDs were learned from this test's FIFO/parent chain.
		for _, pid := range []int{inventoryPid, scannerPid, goPid, ownerPid} {
			if pid > 0 {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		if !joined {
			_ = command.Wait()
		}
	}()
	var grace, bound string
	if _, err := fmt.Fscan(ownerReady, &ownerPid, &grace, &bound); err != nil || ownerPid <= 0 {
		t.Fatalf("owner readiness failed: pid=%d err=%v", ownerPid, err)
	}
	if _, err := fmt.Fscan(ready, &inventoryPid, &scannerPid); err != nil || inventoryPid <= 0 || scannerPid <= 0 {
		t.Fatalf("inventory readiness: pid=%d scanner=%d err=%v", inventoryPid, scannerPid, err)
	}
	parent := exec.CommandContext(ctx, "/bin/ps", "-o", "ppid=", "-p", strconv.Itoa(scannerPid))
	parentOutput, err := parent.Output()
	if err != nil {
		t.Fatal(err)
	}
	goPid, err = strconv.Atoi(strings.TrimSpace(string(parentOutput)))
	if err != nil {
		t.Fatal(err)
	}
	for _, pid := range []int{ownerPid, goPid, scannerPid, inventoryPid} {
		group, err := syscall.Getpgid(pid)
		if err != nil || group != ownerPid {
			t.Errorf("owned PID %d escaped timeout group %d: group=%d err=%v", pid, ownerPid, group, err)
		}
	}
	if grace != "--kill-after=5" || bound != "90" {
		t.Errorf("outer bound changed: grace=%q bound=%q", grace, bound)
	}
	if err := syscall.Kill(ownerPid, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err == nil {
		t.Error("terminated source contract was accepted")
	}
	joined = true
	if ctx.Err() != nil {
		t.Fatal(ctx.Err())
	}
	// The real parent is now joined; an escaped live process is an observable
	// ownership failure, not a structural guess from the group checks above.
	for _, pid := range []int{inventoryPid, scannerPid} {
		if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
			t.Errorf("PID %d survived terminated and joined scanner owner: %v", pid, err)
		}
	}
	scannerProcessesGone(t, inventoryPid, scannerPid, goPid, ownerPid)
	t.Logf("readiness inventory=%d scanner=%d go=%d timeout=%d; TERM propagated, owner joined, all recorded children absent", inventoryPid, scannerPid, goPid, ownerPid)
}
