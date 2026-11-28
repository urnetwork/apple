package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// The app's languages (support inbox 182, 270 and 8621).
//
// The localizations store generates Localizable.xcstrings with every language
// the app ships, Turkish and Persian included, and one AppShortcuts.strings per
// language Siri speaks (Turkish, not Persian). Xcode builds a language only
// when the project's knownRegions lists it, so the catalog's languages must all
// be there. The location list names a country in the app's language with the
// lookup the connection region picker uses, the server's English name the
// fallback.
//
// Reads the project, the catalog and the sources; no Xcode, build or simulator.
// Run: GOWORK=off go test -count=1 test-app-languages_test.go

func appLanguagesRead(t *testing.T, rel string) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the repo root")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(source), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestAppLanguagesKnownRegionsListEveryCatalogLanguage(t *testing.T) {
	project := appLanguagesRead(t, "app/app.xcodeproj/project.pbxproj")
	block := regexp.MustCompile(`(?s)knownRegions = \((.*?)\);`).FindStringSubmatch(project)
	if block == nil {
		t.Fatal("project.pbxproj has no knownRegions")
	}
	known := map[string]bool{}
	for _, region := range strings.Split(block[1], ",") {
		known[strings.Trim(strings.TrimSpace(region), `"`)] = true
	}

	var catalog struct {
		Strings map[string]struct {
			Localizations map[string]json.RawMessage `json:"localizations"`
		} `json:"strings"`
	}
	if err := json.Unmarshal([]byte(appLanguagesRead(t, "app/network/Shared/Resources/Localizable.xcstrings")), &catalog); err != nil {
		t.Fatal(err)
	}
	languages := map[string]bool{}
	for _, entry := range catalog.Strings {
		for language := range entry.Localizations {
			languages[language] = true
		}
	}
	// cs was in the catalog and missing from knownRegions until Turkish and
	// Persian were added
	for _, language := range []string{"tr", "fa", "cs"} {
		if !languages[language] {
			t.Errorf("Localizable.xcstrings carries no %s", language)
		}
	}
	missing := []string{}
	for language := range languages {
		if !known[language] {
			missing = append(missing, language)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("knownRegions does not list %v, so Xcode would not build them", missing)
	}
}

func TestAppLanguagesSiriSpeaksTurkish(t *testing.T) {
	phrases := appLanguagesRead(t, "app/network/Shared/Resources/tr.lproj/AppShortcuts.strings")
	if !strings.Contains(phrases, `"Connect ${applicationName}" = `) {
		t.Error("tr.lproj/AppShortcuts.strings has no Connect phrase")
	}
	catalogTest := appLanguagesRead(t, "app/networkTests/AppShortcutsCatalogTests.swift")
	if !regexp.MustCompile(`(?s)siriLocales = \[[^\]]*"tr"`).MatchString(catalogTest) {
		t.Error("AppShortcutsCatalogTests does not expect a Turkish table")
	}
}

func TestAppLanguagesLocationListNamesCountriesInTheAppLanguage(t *testing.T) {
	group := appLanguagesRead(t, "app/network/Main/Connect/ProviderListGroup/ProviderListGroup.swift")
	if strings.Contains(group, "name: provider.name") || !strings.Contains(group, "name: locationDisplayName(provider)") {
		t.Error("the location list rows do not name a location with locationDisplayName")
	}
	selected := appLanguagesRead(t, "app/network/Main/Connect/SelectedProvider.swift")
	if !strings.Contains(selected, "return locationDisplayName(location)") {
		t.Error("the connect screen's selected location is not named as the list names it")
	}
	utils := appLanguagesRead(t, "app/network/Shared/Utilities/ProviderUtils.swift")
	region := appLanguagesRead(t, "app/network/Shared/ViewModels/ConnectionRegionStore.swift")
	// one lookup for both screens
	const lookup = "locale.localizedString(forRegionCode: "
	if !strings.Contains(utils, lookup) || !strings.Contains(region, lookup) {
		t.Errorf("the location list and the connection region picker do not both name a country with %s…)", lookup)
	}
	if !strings.Contains(utils, "return serverName") {
		t.Error("locationDisplayName does not fall back to the server's name")
	}
}
