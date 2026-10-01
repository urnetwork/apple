package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Parse an export options plist with the system plutil; no Xcode, archive or
// signing identity is involved.
func exportOptions(t *testing.T, name string) map[string]any {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the export options")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := filepath.Join(filepath.Dir(source), "app", name)
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", path).CombinedOutput()
	if err != nil {
		t.Fatalf("%s is not a well-formed plist: %v\n%s", name, err, out)
	}
	options := map[string]any{}
	if err := json.Unmarshal(out, &options); err != nil {
		t.Fatalf("%s did not convert to a JSON object: %v\n%s", name, err, out)
	}
	return options
}

// The direct-download export (build/all/run.sh, macOS direct download region)
// must be a Developer ID export of the same team: anything else either fails
// notarization or produces the store-only signature that does not launch
// outside the Mac App Store. Signing is manual: Xcode's automatic "Mac Team
// Provisioning Profile"s never carry packet-tunnel-provider-systemextension,
// only the account's two Developer ID profiles do, so the export names them
// per bundle id (the same names the targets are signed with in
// project.pbxproj; test-direct-bundle-ids_test.go checks they agree).
func TestDeveloperIDExportOptions(t *testing.T) {
	options := exportOptions(t, "ExportOptions-DeveloperID.plist")
	want := map[string]any{
		"method":             "developer-id",
		"signingStyle":       "manual",
		"signingCertificate": "Developer ID Application",
		"teamID":             "6BGU69Q742",
		"destination":        "export",
		"stripSwiftSymbols":  true,
	}
	for key, value := range want {
		if options[key] != value {
			t.Fatalf("ExportOptions-DeveloperID.plist %s = %v, want %v", key, options[key], value)
		}
	}
	profiles, _ := options["provisioningProfiles"].(map[string]any)
	wantProfiles := map[string]any{
		"com.bringyour.urnetwork":           "URnetwork Download",
		"com.bringyour.urnetwork.extension": "URnetwork Extension Download",
	}
	if len(profiles) != len(wantProfiles) {
		t.Fatalf("ExportOptions-DeveloperID.plist provisioningProfiles = %v, want %v", profiles, wantProfiles)
	}
	for bundleId, name := range wantProfiles {
		if profiles[bundleId] != name {
			t.Fatalf("ExportOptions-DeveloperID.plist provisioningProfiles[%s] = %v, want %v", bundleId, profiles[bundleId], name)
		}
	}
	// App Store Connect upload settings have no place in a Developer ID export
	for _, key := range []string{"uploadSymbols", "manageAppVersionAndBuildNumber", "testFlightInternalTestingOnly", "generateAppStoreInformation"} {
		if _, present := options[key]; present {
			t.Fatalf("ExportOptions-DeveloperID.plist carries the App Store Connect key %s", key)
		}
	}
	if len(options) != len(want)+1 {
		t.Fatalf("ExportOptions-DeveloperID.plist has unexpected keys: %v", options)
	}
}

// The two exports must stay distinct: the App Store plist keeps uploading to
// App Store Connect for the same team, and only the Developer ID plist is a
// developer-id export.
func TestExportOptionsStayDistinct(t *testing.T) {
	store := exportOptions(t, "ExportOptions.plist")
	if store["method"] != "app-store-connect" || store["teamID"] != "6BGU69Q742" {
		t.Fatalf("ExportOptions.plist is no longer the App Store Connect export of the team: %v", store)
	}
	direct := exportOptions(t, "ExportOptions-DeveloperID.plist")
	if direct["method"] == store["method"] {
		t.Fatalf("the Developer ID export uses the App Store method: %v", direct)
	}
	// the App Store export stays automatic; only the direct export pins profiles
	if store["signingStyle"] != "automatic" {
		t.Fatalf("ExportOptions.plist signingStyle = %v, want automatic", store["signingStyle"])
	}
	if _, present := store["provisioningProfiles"]; present {
		t.Fatalf("ExportOptions.plist pins provisioning profiles: %v", store["provisioningProfiles"])
	}
}
