package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// Why the app's earlier processes ended (AppExitDiagnostics, support 8190) is
// Swift that cannot be compiled here, so these tests read its sources. They
// check these things:
//   - the app subscribes to MetricKit at launch, after its log directory is
//     configured, since the sdk writes the file into it, and not under hosted
//     unit tests;
//   - every payload, handed over new or kept from before this start, reaches
//     the sdk with its json and its own times, off the main thread;
//   - nothing in it sends or logs a payload anywhere else: the file the sdk
//     writes leaves the device only inside "send feedback with logs";
//   - only the app process subscribes, in both app targets, and no extension
//     uses MetricKit.
// The sdk pins what it makes of a payload (exit_diagnostics_*_test.go), and
// AppExitDiagnosticsTests and FeedbackLogUploadTests run the Swift through the
// real sdk in CI.

// The Apple repository's root, where this file is.
func exitDiagnosticsRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

// A source file of the repository, by its path from the root.
func exitDiagnosticsRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(exitDiagnosticsRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

const exitDiagnosticsSourcePath = "app/network/Shared/AppExitDiagnostics.swift"

// The app subscribes once its log directory is configured, guarded by
// MetricKit being there, and never under hosted unit tests or a rejected
// hardware test launch.
func TestExitDiagnosticsAppSubscribesAtLaunch(t *testing.T) {
	app := exitDiagnosticsRead(t, "app/network/NetworkApp.swift")
	configure := strings.Index(app, "DiagnosticsLogLocation.configure(processName: DiagnosticsLogLocation.appProcessName)")
	start := strings.Index(app, "AppExitDiagnostics.shared.start()")
	if configure < 0 || start < 0 {
		t.Fatalf("NetworkApp configures its log directory at %d and starts the exit diagnostics at %d; want both", configure, start)
	}
	if start < configure {
		t.Fatal("NetworkApp starts the exit diagnostics before its log directory is configured")
	}
	if strings.Count(app, "AppExitDiagnostics.shared.start()") != 1 {
		t.Fatal("NetworkApp starts the exit diagnostics more than once")
	}
	guarded := regexp.MustCompile(`#if canImport\(MetricKit\)\n(?:[ \t]*//[^\n]*\n)*[ \t]*if startupMode\.allowsStartupInitialization && !hostsUnitTests \{\n[ \t]*AppExitDiagnostics\.shared\.start\(\)\n[ \t]*\}\n[ \t]*#endif`)
	if !guarded.MatchString(app) {
		t.Fatal("the start is not guarded by MetricKit, the startup mode and hosted unit tests")
	}
}

// Every payload reaches the sdk: those MetricKit hands over and those it kept
// from before this start, each with its json and its own times, on the
// subscriber's queue rather than the main thread.
func TestExitDiagnosticsHandsEveryPayloadToTheSdk(t *testing.T) {
	source := exitDiagnosticsRead(t, exitDiagnosticsSourcePath)
	for _, want := range []string{
		"#if canImport(MetricKit)\nimport MetricKit\n#endif",
		"final class AppExitDiagnostics: NSObject, MXMetricManagerSubscriber {",
		"MXMetricManager.shared.add(self)",
		"Self.log(diagnosticPayloads: metricManager.pastDiagnosticPayloads)",
		"Self.log(metricPayloads: metricManager.pastPayloads)",
		"func didReceive(_ payloads: [MXDiagnosticPayload]) {\n        queue.async {\n            Self.log(diagnosticPayloads: payloads)",
		"func didReceive(_ payloads: [MXMetricPayload]) {\n        queue.async {\n            Self.log(metricPayloads: payloads)",
		"String(data: payload.jsonRepresentation(), encoding: .utf8)",
		"SdkLogMetricKitDiagnosticPayload(\n                payloadJson,\n                unixMillis(payload.timeStampBegin),\n                unixMillis(payload.timeStampEnd)\n            )",
		"SdkLogMetricKitMetricPayload(\n                payloadJson,\n                unixMillis(payload.timeStampBegin),\n                unixMillis(payload.timeStampEnd)\n            )",
	} {
		if !strings.Contains(source, want) {
			t.Errorf("AppExitDiagnostics lacks %q", want)
		}
	}
	// the past payloads are read off the main thread too
	start := source[strings.Index(source, "func start() {"):]
	start = start[:strings.Index(start, "\n    }\n")]
	if !strings.Contains(start, "queue.async {") || strings.Index(start, "queue.async {") > strings.Index(start, "pastDiagnosticPayloads") {
		t.Fatal("start reads the past payloads outside the subscriber's queue")
	}
}

// The payloads go only to the sdk, which writes the file: nothing here sends,
// uploads or logs one anywhere else.
func TestExitDiagnosticsSendNothing(t *testing.T) {
	source := exitDiagnosticsRead(t, exitDiagnosticsSourcePath)
	code := []string{}
	for _, line := range strings.Split(source, "\n") {
		if trimmed := strings.TrimSpace(line); !strings.HasPrefix(trimmed, "//") {
			code = append(code, line)
		}
	}
	for _, sent := range []string{
		"URLSession", "URLRequest", "http", "uploadLogs", "SdkApi", "api.", "device.",
		"ClientEvents", "sendFeedback", "SdkLogAppInfo", "print(", "os_log", "Logger(", "NSLog",
	} {
		if strings.Contains(strings.Join(code, "\n"), sent) {
			t.Errorf("AppExitDiagnostics uses %q: a payload leaves only through the sdk's file", sent)
		}
	}
}

// Only the app process subscribes: the file is in the app's synchronized
// folder, which both app targets compile, and no extension uses MetricKit.
func TestExitDiagnosticsOnlyInTheAppProcess(t *testing.T) {
	project := exitDiagnosticsRead(t, "app/app.xcodeproj/project.pbxproj")
	group := regexp.MustCompile(`(D1B95A512CEBDD6900542E0E) /\* network \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = network;`)
	if !group.MatchString(project) {
		t.Fatal("app/network is not a synchronized folder without exceptions")
	}
	targets := regexp.MustCompile(`fileSystemSynchronizedGroups = \(\n\t\t\t\tD1B95A512CEBDD6900542E0E /\* network \*/,\n\t\t\t\);\n\t\t\tname = (\w+);`).FindAllStringSubmatch(project, -1)
	names := []string{}
	for _, target := range targets {
		names = append(names, target[1])
	}
	if strings.Join(names, ",") != "URnetworkDirect,URnetwork" {
		t.Fatalf("app/network is compiled by %v, want the two app targets", names)
	}

	err := filepath.WalkDir(filepath.Join(exitDiagnosticsRoot(t), "app", "extension"), func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(data), "MetricKit") || strings.Contains(string(data), "AppExitDiagnostics") {
			t.Errorf("%s uses MetricKit: only the app process subscribes", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
