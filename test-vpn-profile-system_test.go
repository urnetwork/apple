// The profile boundary uses actual Swift sources with counting framework
// substitutes, then typechecks those sources against the installed native SDK.
package main

import (
	"context"
	"encoding/json"
	"io/fs"
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

// A case is valid executable Swift, not a regular-expression surrogate.
type profileSourceCase struct {
	Name          string   `json:"name"`
	Source        string   `json:"source"`
	WantReject    bool     `json:"want_reject"`
	CompilerFlags []string `json:"compiler_flags,omitempty"`
}

// Copy the real contract and every in-scope Swift input before inserting a
// synthetic control. The original source tree is never modified by a test.
func (self *profileBoundaryBuild) sourceContractTree() string {
	self.t.Helper()
	targetRoot := filepath.Join(self.temporary, "source")
	paths := []string{"test-hardware-startup-lib.sh", "test-hardware-startup.sh",
		"app/networkTests/AppStartupModeTests.swift", "app/networkUITests/HardwareStartupNoVPNUITests.swift"}
	if _, err := os.Stat(filepath.Join(self.root, "test-hardware-profile-scan.go")); err == nil {
		paths = append(paths, "test-hardware-profile-scan.go")
	} else if !os.IsNotExist(err) {
		self.t.Fatal(err)
	}
	err := filepath.WalkDir(filepath.Join(self.root, "app/network"), func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && strings.HasSuffix(path, ".swift") {
			relative, err := filepath.Rel(self.root, path)
			if err != nil {
				return err
			}
			paths = append(paths, relative)
		}
		return nil
	})
	if err != nil {
		self.t.Fatal(err)
	}
	for _, path := range paths {
		data, err := os.ReadFile(filepath.Join(self.root, path))
		if err != nil {
			self.t.Fatal(err)
		}
		target := filepath.Join(targetRoot, path)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			self.t.Fatal(err)
		}
		if err := os.WriteFile(target, data, 0600); err != nil {
			self.t.Fatal(err)
		}
	}
	return targetRoot
}

// A conditional caller deliberately disables shell errexit. The function's
// own error propagation must enforce the complete source contract.
func (self *profileBoundaryBuild) sourceContract(root string, environment ...string) (string, int) {
	self.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/bash", "-c",
		`set -euo pipefail; source "$1"; if apple_hardware_source_contract "$2"; then exit 0; else exit 1; fi`,
		"profile-contract", filepath.Join(root, "test-hardware-startup-lib.sh"), root)
	command.Env = append(os.Environ(), environment...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 2 * time.Second
	output, err := command.CombinedOutput()
	if ctx.Err() != nil {
		self.t.Fatal(ctx.Err())
	}
	if err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			return string(output), exitError.ExitCode()
		}
		self.t.Fatal(err)
	}
	return string(output), 0
}

// Native SDK typechecking precedes each actual-contract assertion. Ordinary
// formatting, literals and interpolation cannot change the profile boundary.
func TestProfileSourceContractSyntax(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	root := build.sourceContractTree()
	data, err := os.ReadFile(filepath.Join(build.fixtures, "SourceContractCases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []profileSourceCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	control := filepath.Join(root, "app/network/ProfileBoundaryAuditControl.swift")
	for _, c := range cases {
		if err := os.WriteFile(control, []byte(c.Source), 0600); err != nil {
			t.Fatal(err)
		}
		arguments := []string{"-typecheck", "-swift-version", "5", "-j", "2", "-num-threads", "2",
			"-module-cache-path", filepath.Join(build.temporary, "native-module-cache"),
			"-module-name", "ProfileBoundaryAudit",
			filepath.Join(build.fixtures, "SourceContractSupport.swift"),
			filepath.Join(root, "app/network/Shared/AppStartupMode.swift"),
			filepath.Join(root, "app/network/Shared/VPNProfileSystem.swift"), control}
		build.run("/usr/bin/swiftc", append(arguments, c.CompilerFlags...)...)
		output, code := build.sourceContract(root)
		if c.WantReject {
			if code != 1 || !strings.Contains(output, control+":") {
				t.Errorf("%s native-valid raw operation accepted or not diagnosed: exit=%d output=%s", c.Name, code, output)
				continue
			}
		} else if code != 0 {
			t.Errorf("%s native-valid safe source rejected: exit=%d output=%s", c.Name, code, output)
			continue
		}
		t.Logf("%s native-valid compiler_flags=%v contract_exit=%d expected=true", c.Name, c.CompilerFlags, code)
	}
}

// Malformed/oversized source and observation failures never become a clean
// contract, including callers for which shell errexit is disabled.
func TestProfileSourceContractFailsClosed(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	root := build.sourceContractTree()
	control := filepath.Join(root, "app/network/ProfileBoundaryAuditControl.swift")
	for _, c := range []struct {
		name   string
		source string
	}{
		{name: "unterminated-comment", source: "/* unterminated"},
		{name: "unterminated-string", source: `let value = "unterminated`},
		{name: "unterminated-backtick", source: "let `unterminated"},
		{name: "unterminated-interpolation", source: `let value = "\(manager`},
		{name: "unsupported-regex", source: `let value = #/manager.saveToPreferences/#`},
		{name: "invalid-utf8", source: "// invalid\xff"},
		{name: "comment-nesting-limit", source: strings.Repeat("/*", 257) + strings.Repeat("*/", 257)},
		{name: "file-byte-limit", source: "//" + strings.Repeat("x", 16*1024*1024)},
		{name: "token-limit", source: strings.Repeat("()", 1024*1024)},
	} {
		if err := os.WriteFile(control, []byte(c.source), 0600); err != nil {
			t.Fatal(err)
		}
		output, code := build.sourceContract(root)
		if code != 1 || !strings.Contains(output, "profile source scan:") {
			t.Errorf("%s did not fail closed with a scanner diagnostic: exit=%d output=%s", c.name, code, output)
		} else {
			t.Logf("%s failed closed", c.name)
		}
	}
	if err := os.WriteFile(control, []byte("// clean source\n"), 0600); err != nil {
		t.Fatal(err)
	}
	fakeBin := filepath.Join(build.temporary, "fake-bin")
	if err := os.Mkdir(fakeBin, 0700); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name   string
		script string
	}{
		{name: "inventory-empty-error", script: "exit 2\n"},
		{name: "inventory-partial-error", script: "printf '%s\\0' \"$PROFILE_AUDIT_CONTROL\"\nexit 2\n"},
		{name: "inventory-missing-file", script: "printf '%s\\0' \"$PROFILE_AUDIT_CONTROL.missing\"\n"},
		{name: "inventory-not-nul-terminated", script: "printf '%s' \"$PROFILE_AUDIT_CONTROL\"\n"},
		{name: "inventory-out-of-scope", script: "printf '/outside-synthetic-root.swift\\0'\n"},
		{name: "inventory-output-limit", script: "head -c 9000000 /dev/zero\n"},
	} {
		if err := os.WriteFile(filepath.Join(fakeBin, "rg"), []byte("#!/bin/sh\n"+c.script), 0700); err != nil {
			t.Fatal(err)
		}
		output, code := build.sourceContract(root, "PATH="+fakeBin+":"+os.Getenv("PATH"), "PROFILE_AUDIT_CONTROL="+control)
		if code != 1 || !strings.Contains(output, "profile source scan:") {
			t.Errorf("%s did not fail closed: exit=%d output=%s", c.name, code, output)
		} else {
			t.Logf("%s failed closed", c.name)
		}
	}
	helper := filepath.Join(root, "test-hardware-profile-scan.go")
	if _, err := os.Stat(helper); err == nil {
		if err := os.Rename(helper, helper+".held"); err != nil {
			t.Fatal(err)
		}
		output, code := build.sourceContract(root)
		if code != 1 {
			t.Errorf("missing helper passed: exit=%d output=%s", code, output)
		}
		if err := os.Rename(helper+".held", helper); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(fakeBin, "rg")); err != nil {
			t.Fatal(err)
		}
		timeoutPath, err := exec.LookPath("timeout")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(timeoutPath, filepath.Join(fakeBin, "timeout")); err != nil {
			t.Fatal(err)
		}
		output, code = build.sourceContract(root, "PATH="+fakeBin+":/usr/bin:/bin")
		if code != 1 || !strings.Contains(output, "go") {
			t.Errorf("missing Go tool passed: exit=%d output=%s", code, output)
		}
		goPath, err := exec.LookPath("go")
		if err != nil {
			t.Fatal(err)
		}
		output, code = build.sourceContract(root, "PATH="+filepath.Dir(goPath)+":"+fakeBin+":/usr/bin:/bin")
		if code != 1 || !strings.Contains(output, "Swift inventory failed") {
			t.Errorf("missing rg tool passed: exit=%d output=%s", code, output)
		}
	} else {
		t.Errorf("source contract has no required lexical helper: %v", err)
	}
	t.Log("full contract failure controls completed; all owned children joined")
}

// Compile the actual scanner into a race-enabled test binary. The fixture uses
// readiness FIFOs to force cancellation while its inventory child is running.
func TestProfileSourceScannerLifecycle(t *testing.T) {
	build := newProfileBoundaryBuild(t)
	root := build.sourceContractTree()
	paths := []struct {
		source string
		target string
	}{
		{source: filepath.Join(build.root, "test-hardware-profile-scan.go"), target: "scanner.go"},
		{source: filepath.Join(build.fixtures, "ScannerLifecycle_test.go"), target: "scanner_test.go"},
	}
	for _, path := range paths {
		data, err := os.ReadFile(path.source)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(build.temporary, path.target), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	output := build.run("go", "test", "-race", "-p", "1", "-parallel", "1", "-count=1", "-v",
		filepath.Join(build.temporary, "scanner.go"), filepath.Join(build.temporary, "scanner_test.go"),
		"-args", "-profile-source-root", root)
	t.Log(strings.TrimSpace(output))
}
