package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The direct-download build's in-app updater (app/network/Shared/Updater)
// replaces the running bundle under /Applications through a folder the user
// picks once in an open panel. In the sandbox that needs user-selected files
// READ-WRITE (the project setting that becomes
// com.apple.security.files.user-selected.read-write) and an app-scoped
// bookmark entitlement so the choice persists; both are sandbox entitlements,
// not profile-granted ones, so the Developer ID profile is unaffected. The
// App Store target keeps read-only: it updates through the store and does
// not compile the updater.
func TestDirectTargetCanReplaceItselfUnderApplications(t *testing.T) {
	for _, configuration := range []string{"Debug", "Release"} {
		direct := targetBuildSettings(t, "URnetworkDirect", configuration)
		if direct["ENABLE_APP_SANDBOX"] != "YES" {
			t.Fatalf("URnetworkDirect %s is not sandboxed: ENABLE_APP_SANDBOX = %q", configuration, direct["ENABLE_APP_SANDBOX"])
		}
		if direct["ENABLE_USER_SELECTED_FILES"] != "readwrite" {
			t.Fatalf("URnetworkDirect %s ENABLE_USER_SELECTED_FILES = %q, want readwrite (the updater replaces the bundle in the user-granted Applications folder)", configuration, direct["ENABLE_USER_SELECTED_FILES"])
		}
		store := targetBuildSettings(t, "URnetwork", configuration)
		if store["ENABLE_USER_SELECTED_FILES"] != "readonly" {
			t.Fatalf("URnetwork %s ENABLE_USER_SELECTED_FILES = %q, want readonly (the App Store build does not self-update)", configuration, store["ENABLE_USER_SELECTED_FILES"])
		}
	}

	direct := plistJSON(t, filepath.Join(repoRoot(t), "app", "network", "network-macOS-direct.entitlements"))
	if direct["com.apple.security.files.bookmarks.app-scope"] != true {
		t.Fatalf("network-macOS-direct.entitlements lacks com.apple.security.files.bookmarks.app-scope = true: %v", direct)
	}
	store := plistJSON(t, filepath.Join(repoRoot(t), "app", "network", "network-macOS.entitlements"))
	if _, present := store["com.apple.security.files.bookmarks.app-scope"]; present {
		t.Fatal("network-macOS.entitlements gained the updater's bookmark entitlement")
	}
}

// The updater code paths exist only in the direct-download build: the
// framework-facing DirectUpdater compiles under DIRECT_DOWNLOAD on macOS, and
// nothing outside that flag refers to it. The pure decisions
// (ReleaseSelection, UpdateInstallPlan) compile everywhere so the unit tests
// run them on the iOS simulator.
func TestUpdaterIsDirectDownloadOnly(t *testing.T) {
	root := filepath.Join(repoRoot(t), "app", "network")
	updater, err := os.ReadFile(filepath.Join(root, "Shared", "Updater", "DirectUpdater.swift"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(updater), "#if os(macOS) && DIRECT_DOWNLOAD\n") {
		t.Fatal("DirectUpdater.swift is not gated on os(macOS) && DIRECT_DOWNLOAD")
	}
	for _, name := range []string{"ReleaseSelection.swift", "UpdateInstallPlan.swift"} {
		pure, err := os.ReadFile(filepath.Join(root, "Shared", "Updater", name))
		if err != nil {
			t.Fatal(err)
		}
		for _, forbidden := range []string{"import AppKit", "import Security", "URLSession", "Process(", "FileManager"} {
			if strings.Contains(string(pure), forbidden) {
				t.Fatalf("%s is no longer pure: it mentions %s", name, forbidden)
			}
		}
	}
	// every reference outside the updater directory sits inside a
	// DIRECT_DOWNLOAD block
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".swift") || strings.Contains(path, "/Shared/Updater/") {
			return err
		}
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !strings.Contains(string(source), "DirectUpdater") {
			return nil
		}
		depth := 0
		for number, line := range strings.Split(string(source), "\n") {
			trimmed := strings.TrimSpace(line)
			switch {
			case strings.HasPrefix(trimmed, "#if ") && strings.Contains(trimmed, "DIRECT_DOWNLOAD") && !strings.Contains(trimmed, "!DIRECT_DOWNLOAD"):
				depth++
			case strings.HasPrefix(trimmed, "#if "):
				// an unrelated block nested inside counts as inside
				if depth > 0 {
					depth++
				}
			case strings.HasPrefix(trimmed, "#endif"):
				if depth > 0 {
					depth--
				}
			}
			if strings.Contains(line, "DirectUpdater") && depth == 0 && !strings.HasPrefix(trimmed, "//") {
				t.Fatalf("%s:%d refers to DirectUpdater outside a DIRECT_DOWNLOAD block", path, number+1)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
