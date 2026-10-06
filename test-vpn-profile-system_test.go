// The profile boundary uses actual Swift sources with counting framework
// substitutes, then typechecks those sources against the installed native SDK.
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

// All generated modules/binaries belong to one test and are joined before its
// temporary directory is removed. Real NetworkExtension is never executed.
type profileBoundaryBuild struct {
	t         *testing.T
	root      string
	fixtures  string
	temporary string
}

// Locate the shipped sources; an explicit alternate root enables running the
// same regression against an immutable pre-fix source copy.
func newProfileBoundaryBuild(t *testing.T) *profileBoundaryBuild {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Fatal("profile native checks require the Apple SDK")
	}
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate Apple source")
	}
	root := filepath.Dir(source)
	fixtures := filepath.Join(root, "tests/native/profile-boundary")
	if alternate := os.Getenv("UR_PROFILE_BOUNDARY_SOURCE_ROOT"); alternate != "" {
		root = alternate
	}
	return &profileBoundaryBuild{t: t, root: root, fixtures: fixtures, temporary: t.TempDir()}
}

// Run one bounded owned process group, preserving compiler/runtime failures.
func (self *profileBoundaryBuild) run(name string, args ...string) string {
	self.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGTERM) }
	command.WaitDelay = 5 * time.Second
	output, err := command.CombinedOutput()
	if err != nil {
		self.t.Fatalf("profile boundary command %s failed: %v\n%s", name, err, output)
	}
	return string(output)
}

// Compile the fake SDK independently so the real controller imports its
// existing dependency names without source rewriting or test conditionals.
func (self *profileBoundaryBuild) module(name string) {
	self.t.Helper()
	self.run("/usr/bin/swiftc", "-swift-version", "5", "-j", "2", "-num-threads", "2",
		"-module-cache-path", filepath.Join(self.temporary, "module-cache"),
		"-emit-library", "-emit-module", "-module-name", name,
		"-emit-module-path", filepath.Join(self.temporary, name+".swiftmodule"),
		filepath.Join(self.fixtures, name+".swift"), "-o", filepath.Join(self.temporary, "lib"+name+".dylib"))
}

// Compile exact production gateway/controller bytes with their pure planners.
func (self *profileBoundaryBuild) arguments() []string {
	return []string{"-swift-version", "5", "-j", "2", "-num-threads", "2",
		"-module-cache-path", filepath.Join(self.temporary, "module-cache"),
		"-I", self.temporary,
		filepath.Join(self.root, "app/network/Shared/VPNProfileSystem.swift"),
		filepath.Join(self.root, "app/network/Shared/SplitTunnel/SplitTunnelProxyController.swift"),
		filepath.Join(self.root, "app/network/Shared/SplitTunnel/SplitTunnelProxyPlan.swift"),
		filepath.Join(self.root, "app/network/Shared/SplitTunnel/SplitTunnelProxyConfiguration.swift"),
		filepath.Join(self.root, "app/network/Shared/SystemExtension/SystemExtensionActivation.swift"),
		filepath.Join(self.fixtures, "Support.swift")}
}

// Both policy-denied controller entry and an admitted save's delayed callback
// must reach the same gateway. This executes on the original source as well.
func TestSplitTunnelProfileAccessBoundary(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	build.module("NetworkExtension")
	build.module("URnetworkSdk")
	args := append(build.arguments(), filepath.Join(build.fixtures, "ControllerMain.swift"),
		"-L", build.temporary, "-lNetworkExtension", "-lURnetworkSdk",
		"-Xlinker", "-rpath", "-Xlinker", build.temporary, "-o", filepath.Join(build.temporary, "controller"))
	build.run("/usr/bin/swiftc", args...)
	output := build.run(filepath.Join(build.temporary, "controller"))
	if !strings.Contains(output, "controller profile boundary: 7 semantic checks passed") {
		t.Fatalf("unexpected controller boundary result: %s", output)
	}
	t.Log(strings.TrimSpace(output))
}

// Every gateway operation denies both non-production modes and forwards the
// existing production semantics, including exact completion and option values.
func TestVpnProfileSystemOperations(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	build.module("NetworkExtension")
	build.module("URnetworkSdk")
	args := append(build.arguments(), filepath.Join(build.fixtures, "GatewayMain.swift"),
		"-L", build.temporary, "-lNetworkExtension", "-lURnetworkSdk",
		"-Xlinker", "-rpath", "-Xlinker", build.temporary, "-o", filepath.Join(build.temporary, "gateway"))
	build.run("/usr/bin/swiftc", args...)
	output := build.run(filepath.Join(build.temporary, "gateway"))
	if !strings.Contains(output, "gateway profile boundary: 57 semantic checks passed") {
		t.Fatalf("unexpected gateway boundary result: %s", output)
	}
	t.Log(strings.TrimSpace(output))
}

// With no fake NetworkExtension module on the search path, verify the shared
// NEVPNManager base, macOS-only types and callback signatures against Apple.
func TestVpnProfileSystemNativeSdkTypes(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	build.module("URnetworkSdk")
	build.run("/usr/bin/swiftc", append([]string{"-typecheck"}, build.arguments()...)...)
}
