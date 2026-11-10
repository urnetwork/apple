package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// App Transport Security stays at Apple's defaults in every bundle: no
// Info.plist has an NSAppTransportSecurity dictionary. Until 2026-11-10,
// URnetwork-Info.plist (the iOS app, the App Store Mac app and the
// direct-download Mac app) set NSAllowsArbitraryLoads, which turned ATS off
// for every host, so any URLSession or WKWebView load in the app could use
// cleartext http or weak TLS.
//
// Nothing needs it: the app's own URLSession and WKWebView loads are all
// https (the ur.io checkout pages, the GitHub releases of the direct-download
// updater, Google sign-in), and the api, DoH, extender and tunnel traffic runs
// in the sdk's Go networking, which ATS does not cover. If a real feature
// ever needs an exception, it is a per-domain NSExceptionDomains entry with
// its reason, changed here together with the plist; never
// NSAllowsArbitraryLoads.
//
// Parsed with the system plutil, so XML comments in a plist are not read as
// keys; no Xcode, build or simulator is involved.

func atsRepoRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the repo root")
	}
	return filepath.Dir(source)
}

// The Info.plist of every target: the INFOPLIST_FILE values of
// project.pbxproj (plain or sdk-conditional), relative to app/.
func atsTargetInfoPlists(pbx string) []string {
	re := regexp.MustCompile(`(?m)^\s*"?INFOPLIST_FILE(\[[^\]]*\])?"? = "?([^";]+)"?;`)
	var plists []string
	for _, match := range re.FindAllStringSubmatch(pbx, -1) {
		plist := strings.TrimSpace(match[2])
		plist = strings.TrimPrefix(plist, "$(SRCROOT)/")
		plist = strings.TrimPrefix(plist, "${SRCROOT}/")
		plists = append(plists, plist)
	}
	return plists
}

// Every Info plist in the app sources, relative to app/, for a plist no
// target names (yet): the walk skips build output and bundles.
func atsSourceInfoPlists(t *testing.T, app string) []string {
	t.Helper()
	name := regexp.MustCompile(`^(.+-)?Info(-.+)?\.plist$`)
	skip := regexp.MustCompile(`^(build|DerivedData|xcuserdata|\..*|.*\.(xcarchive|xcodeproj|xcworkspace|xcresult|xcassets|app|appex|systemextension|framework|xcframework|bundle))$`)
	var plists []string
	err := filepath.WalkDir(app, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if path != app && skip.MatchString(entry.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if name.MatchString(entry.Name()) {
			relative, err := filepath.Rel(app, path)
			if err != nil {
				return err
			}
			plists = append(plists, filepath.ToSlash(relative))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return plists
}

func atsPlistJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", path).CombinedOutput()
	if err != nil {
		t.Fatalf("%s is not a well-formed plist: %v\n%s", path, err, out)
	}
	object := map[string]any{}
	if err := json.Unmarshal(out, &object); err != nil {
		t.Fatalf("%s did not convert to a JSON object: %v\n%s", path, err, out)
	}
	return object
}

func TestNoInfoPlistDisablesAppTransportSecurity(t *testing.T) {
	app := filepath.Join(atsRepoRoot(t), "app")
	pbxBytes, err := os.ReadFile(filepath.Join(app, "app.xcodeproj", "project.pbxproj"))
	if err != nil {
		t.Fatal(err)
	}
	pbx := string(pbxBytes)

	targets := map[string]bool{}
	for _, plist := range atsTargetInfoPlists(pbx) {
		targets[plist] = true
	}
	sources := map[string]bool{}
	for _, plist := range atsSourceInfoPlists(t, app) {
		sources[plist] = true
	}

	// CONTROL: both scans see the app and every extension, so a pbxproj the
	// regexp no longer matches, or a walk that skips too much, cannot pass by
	// finding nothing
	for _, want := range []string{
		"URnetwork-Info.plist",              // iOS, App Store Mac and direct-download Mac app
		"extension/Info.plist",              // packet tunnel app extension
		"extension/Info-macOS-sysext.plist", // direct-download packet tunnel system extension
		"splittunnel/Info.plist",            // App Store split tunnel
		"splittunnel/Info-direct.plist",     // direct-download split tunnel
		"widgets/Info.plist",                // widgets
	} {
		if !targets[want] {
			t.Fatalf("CONTROL FAILED: no target builds from %s", want)
		}
		if !sources[want] {
			t.Fatalf("CONTROL FAILED: the source walk missed %s", want)
		}
	}
	if !sources["URnetworkLaunchHelper/Info.plist"] {
		t.Fatal("CONTROL FAILED: the source walk missed URnetworkLaunchHelper/Info.plist")
	}

	all := map[string]bool{}
	for plist := range targets {
		all[plist] = true
	}
	for plist := range sources {
		all[plist] = true
	}
	plists := make([]string, 0, len(all))
	for plist := range all {
		plists = append(plists, plist)
	}
	sort.Strings(plists)

	for _, plist := range plists {
		info := atsPlistJSON(t, filepath.Join(app, filepath.FromSlash(plist)))
		if len(info) == 0 {
			t.Fatalf("CONTROL FAILED: %s parsed to no keys", plist)
		}
		if ats, present := info["NSAppTransportSecurity"]; present {
			t.Errorf("%s sets NSAppTransportSecurity = %v; App Transport Security must keep its defaults", plist, ats)
		}
	}

	// Info.plist keys from build settings (GENERATE_INFOPLIST_FILE) or a
	// script phase that writes them
	for _, key := range []string{"NSAppTransportSecurity", "NSAllowsArbitraryLoads"} {
		if strings.Contains(pbx, key) {
			t.Errorf("project.pbxproj names %s", key)
		}
	}
}
