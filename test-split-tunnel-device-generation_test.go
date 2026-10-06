// Go drives the actual Swift controller with synthetic SDK/framework modules.
// A same-file extension exposes setup/read access only; no method is replaced.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

var deviceGenerationHarnessPath string

// One native build serves all separately named lifecycle tests. Process
// completion joins every owned child before its temporary tree is removed.
func TestMain(m *testing.M) {
	code := func() int {
		if runtime.GOOS != "darwin" {
			fmt.Fprintln(os.Stderr, "device generation native checks require macOS")
			return 1
		}
		_, source, _, ok := runtime.Caller(0)
		if !ok {
			fmt.Fprintln(os.Stderr, "cannot locate device generation test source")
			return 1
		}
		root := filepath.Dir(source)
		fixtures := filepath.Join(root, "tests/native/device-generation")
		if alternate := os.Getenv("UR_DEVICE_GENERATION_SOURCE_ROOT"); alternate != "" {
			root = alternate
		}
		temporary, err := os.MkdirTemp("", "urnetwork-device-generation-")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("device generation start UTC=%s source=%s build=%s\n", time.Now().UTC().Format(time.RFC3339Nano), root, temporary)
		defer func() {
			if err := os.RemoveAll(temporary); err != nil {
				panic(err)
			}
			fmt.Printf("device generation cleanup UTC=%s removed=%s all children joined\n", time.Now().UTC().Format(time.RFC3339Nano), temporary)
		}()
		deviceGenerationHarnessPath, err = buildDeviceGenerationHarness(root, fixtures, temporary)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return m.Run()
	}()
	os.Exit(code)
}

// Run one bounded owned process group; timeouts detect deadlocks, never prove
// that an absent callback was ignored. Test assertions follow an explicit FIFO.
func deviceGenerationCommand(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGTERM) }
	command.WaitDelay = 5 * time.Second
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("%s failed: %w\n%s", name, err, output)
	}
	return output, nil
}

// Only the test extension is appended. The exact controller source prefix and
// all other actual production files are hashed and compiled without rewriting.
func buildDeviceGenerationHarness(root string, fixtures string, temporary string) (string, error) {
	common := []string{"-swift-version", "5", "-j", "2", "-num-threads", "2", "-module-cache-path", filepath.Join(temporary, "module-cache")}
	if sanitizer := os.Getenv("UR_DEVICE_GENERATION_SANITIZER"); sanitizer != "" {
		if sanitizer != "thread" {
			return "", fmt.Errorf("unsupported native sanitizer %q", sanitizer)
		}
		common = append(common, "-sanitize=thread")
	}
	for _, module := range []string{"NetworkExtension", "URnetworkSdk"} {
		args := append(append([]string{}, common...), "-emit-library", "-emit-module", "-module-name", module,
			"-emit-module-path", filepath.Join(temporary, module+".swiftmodule"),
			filepath.Join(fixtures, module+".swift"), "-o", filepath.Join(temporary, "lib"+module+".dylib"))
		if _, err := deviceGenerationCommand("/usr/bin/swiftc", args...); err != nil {
			return "", err
		}
	}
	controllerPath := filepath.Join(root, "app/network/Shared/SplitTunnel/SplitTunnelProxyController.swift")
	controller, err := os.ReadFile(controllerPath)
	if err != nil {
		return "", err
	}
	seam, err := os.ReadFile(filepath.Join(fixtures, "ControllerSeam.swift"))
	if err != nil {
		return "", err
	}
	joinedPath := filepath.Join(temporary, "ControllerWithSeam.swift")
	if err := os.WriteFile(joinedPath, append(append(controller, '\n'), seam...), 0600); err != nil {
		return "", err
	}
	harnessPath := filepath.Join(temporary, "device-generation")
	sourcePaths := []string{
		filepath.Join(root, "app/network/Shared/VPNProfileSystem.swift"),
		filepath.Join(root, "app/network/Shared/SplitTunnel/SplitTunnelProxyConfiguration.swift"),
		filepath.Join(root, "app/network/Shared/SplitTunnel/SplitTunnelProxyPlan.swift"),
		filepath.Join(root, "app/network/Shared/SystemExtension/SystemExtensionActivation.swift"),
		filepath.Join(fixtures, "Support.swift"), filepath.Join(fixtures, "ControllerMain.swift"),
	}
	for _, path := range append(append([]string{controllerPath}, sourcePaths...), filepath.Join(fixtures, "ControllerSeam.swift")) {
		contents, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		fmt.Printf("device generation source sha256=%x path=%s\n", sha256.Sum256(contents), path)
	}
	args := append(append([]string{}, common...), "-I", temporary, "-L", temporary,
		"-lNetworkExtension", "-lURnetworkSdk", "-Xlinker", "-rpath", "-Xlinker", temporary, joinedPath)
	args = append(args, sourcePaths...)
	args = append(args, "-o", harnessPath)
	if _, err := deviceGenerationCommand("/usr/bin/swiftc", args...); err != nil {
		return "", err
	}
	links, err := deviceGenerationCommand("/usr/bin/otool", "-L", harnessPath)
	if err != nil {
		return "", err
	}
	if strings.Contains(string(links), "/NetworkExtension.framework/") ||
		!strings.Contains(string(links), filepath.Join(temporary, "libNetworkExtension.dylib")) ||
		!strings.Contains(string(links), filepath.Join(temporary, "libURnetworkSdk.dylib")) {
		return "", fmt.Errorf("unexpected framework links:\n%s", links)
	}
	fmt.Println("device generation links: owned fake NetworkExtension and URnetworkSdk; no real NetworkExtension framework")
	return harnessPath, nil
}

// Execute each scenario in a fresh process, then join it and report all native
// assertions. The real main queue ordering needs no timing-based negative test.
func runDeviceGenerationScenario(t *testing.T, scenario string) {
	t.Helper()
	output, err := deviceGenerationCommand(deviceGenerationHarnessPath, scenario)
	t.Logf("%s", output)
	if err != nil {
		t.Fatal(err)
	}
}

// The old device must not start the replacement's proxy.
func TestRetiredConnectCannotStartReplacement(t *testing.T) {
	runDeviceGenerationScenario(t, "retired-connect-replacement")
}

// The old device must not stop the replacement's proxy.
func TestRetiredDisconnectCannotStopReplacement(t *testing.T) {
	runDeviceGenerationScenario(t, "retired-disconnect-replacement")
}

// Removing a device invalidates already-enqueued connect work.
func TestRetiredConnectCannotStartAfterDetach(t *testing.T) {
	runDeviceGenerationScenario(t, "detach")
}

// A second subscription to the same object is a distinct generation.
func TestSameDeviceReattachRejectsRetiredCallback(t *testing.T) {
	runDeviceGenerationScenario(t, "same-device")
}

// Object identity alone cannot separate the first and third subscriptions.
func TestDeviceAbaRejectsRetiredCallback(t *testing.T) {
	runDeviceGenerationScenario(t, "aba")
}

// A captured listener selected before close can arrive after replacement.
func TestClosedSubscriptionLateDeliveryIsIgnored(t *testing.T) {
	runDeviceGenerationScenario(t, "closed-late-delivery")
}

// Teardown closes the subscription and queued weak callbacks have no owner.
func TestQueuedCallbackAfterControllerDeinitDoesNothing(t *testing.T) {
	runDeviceGenerationScenario(t, "deinit")
}

// The current subscription still drives both transitions.
func TestLiveDeviceConnectAndDisconnectRemainActive(t *testing.T) {
	runDeviceGenerationScenario(t, "live")
}
