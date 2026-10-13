package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The network payout consent (VERSION2-FINAL §11.1) is Swift that cannot be
// compiled here, so these tests read its sources (CONSENT.md §6). They check
// three things. The eleven sn_consent_* strings are spelled exactly as the
// localization store pins them, and the catalog translates each one. Each
// state of the consent card shows its own strings. And the app sends back
// only the server-issued message. The Swift unit tests
// (NetworkConsentFlowTests) run the same behaviour in CI.

// The store's Apple source for each key: the xcstrings key, which is the
// literal a SwiftUI Text or String(localized:) looks up. {coldkey} is a Swift
// interpolation, so its catalog key ends in %@.
var consentKeys = []struct {
	id      string
	literal string
	catalog string
}{
	{"sn_consent_title", `"Payout consent"`, "Payout consent"},
	{"sn_consent_none", `"No payout wallet yet. Earnings aren't paid until you sign."`, "No payout wallet yet. Earnings aren't paid until you sign."},
	{"sn_consent_body", `"Sign once with your Bittensor wallet so this network's earnings are paid to it."`, "Sign once with your Bittensor wallet so this network's earnings are paid to it."},
	{"sn_consent_sign", `"Sign with wallet"`, "Sign with wallet"},
	{"sn_consent_signing", `"Waiting for your wallet's signature…"`, "Waiting for your wallet's signature…"},
	{"sn_consent_active", `"Earnings are paid to \(`, "Earnings are paid to %@"},
	{"sn_consent_change", `"Change wallet"`, "Change wallet"},
	{"sn_consent_change_note", `"A new wallet takes effect from the next epoch."`, "A new wallet takes effect from the next epoch."},
	{"sn_consent_expired", `"The request expired. Try again."`, "The request expired. Try again."},
	{"sn_consent_failed", `"The signature didn't match this wallet. Try again."`, "The signature didn't match this wallet. Try again."},
	{"sn_consent_owner_only", `"Only the network owner can choose the payout wallet."`, "Only the network owner can choose the payout wallet."},
}

// the Swift the consent lives in
var consentSourceFiles = []string{
	"app/network/Main/Account/Earnings/EarningsTiles.swift",
	"app/network/Main/Account/Earnings/NetworkConsentFlow.swift",
	"app/network/Main/Account/Earnings/NetworkConsentSheet.swift",
}

func consentRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func consentRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(consentRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// The text of a Swift declaration at an indent, from its line to the first
// closing brace at that indent.
func consentDeclaration(t *testing.T, source string, indent string, declaration string) string {
	t.Helper()
	start := strings.Index(source, "\n"+indent+declaration)
	if start < 0 {
		t.Fatalf("no %q", declaration)
	}
	end := strings.Index(source[start:], "\n"+indent+"}\n")
	if end < 0 {
		t.Fatalf("%q does not close", declaration)
	}
	return source[start : start+end]
}

// the Swift literal of a key
func consentLiteral(t *testing.T, id string) string {
	t.Helper()
	for _, key := range consentKeys {
		if key.id == id {
			return key.literal
		}
	}
	t.Fatalf("no key %s", id)
	return ""
}

// CS-10: every key is looked up exactly as the store spells it, and the
// catalog has it in every locale the catalog ships
func TestNetworkConsentStringsAreThePinnedKeys(t *testing.T) {
	var sources strings.Builder
	for _, rel := range consentSourceFiles {
		sources.WriteString(consentRead(t, rel))
	}
	for _, key := range consentKeys {
		if !strings.Contains(sources.String(), key.literal) {
			t.Errorf("%s: no Swift call site spells %s", key.id, key.literal)
		}
	}

	var catalog struct {
		Strings map[string]struct {
			ExtractionState string `json:"extractionState"`
			Localizations   map[string]struct {
				StringUnit struct {
					Value string `json:"value"`
				} `json:"stringUnit"`
			} `json:"localizations"`
		} `json:"strings"`
	}
	if err := json.Unmarshal([]byte(consentRead(t, "app/network/Shared/Resources/Localizable.xcstrings")), &catalog); err != nil {
		t.Fatal(err)
	}
	locales := map[string]bool{}
	for _, entry := range catalog.Strings {
		for locale := range entry.Localizations {
			locales[locale] = true
		}
	}
	if !locales["zh-Hans"] || len(locales) < 27 {
		t.Fatalf("the catalog ships %d locales", len(locales))
	}
	for _, key := range consentKeys {
		entry, ok := catalog.Strings[key.catalog]
		if !ok {
			t.Errorf("%s: the catalog has no %q", key.id, key.catalog)
			continue
		}
		if entry.ExtractionState == "stale" {
			t.Errorf("%s: %q is stale", key.id, key.catalog)
		}
		for locale := range locales {
			value := entry.Localizations[locale].StringUnit.Value
			if value == "" {
				t.Errorf("%s: no %s translation", key.id, locale)
			}
			if strings.Contains(value, "%@") != strings.Contains(key.catalog, "%@") {
				t.Errorf("%s: %s does not keep the coldkey: %q", key.id, locale, value)
			}
		}
	}
}

// CS-7, CS-8: without a consent the card says earnings are not paid and
// offers to sign; with one it names the coldkey and offers to change it,
// from the next epoch
func TestNetworkConsentCardStates(t *testing.T) {
	card := consentDeclaration(t, consentRead(t, consentSourceFiles[0]), "", "struct NetworkConsentCard: View")
	none := strings.Index(card, "case .noConsent:")
	active := strings.Index(card, "case .active(")
	if none < 0 || active < none {
		t.Fatal("the card has no .noConsent then .active state")
	}
	branches := map[string]string{
		"none":   card[none:active],
		"active": card[active:],
	}
	for state, ids := range map[string][]string{
		"none":   {"sn_consent_none", "sn_consent_body", "sn_consent_sign"},
		"active": {"sn_consent_active", "sn_consent_change", "sn_consent_change_note"},
	} {
		for _, id := range ids {
			if !strings.Contains(branches[state], consentLiteral(t, id)) {
				t.Errorf("the %s card does not show %s", state, id)
			}
		}
	}
	if strings.Contains(branches["active"], consentLiteral(t, "sn_consent_sign")) || strings.Contains(branches["none"], consentLiteral(t, "sn_consent_change")) {
		t.Error("a card state offers the other state's action")
	}
}

// CS-9: the wallet signs the challenge as the SDK returned it, the proof
// goes back only when it carries that message for that coldkey, and nothing
// else in the app submits a consent
func TestNetworkConsentSignsOnlyTheServerMessage(t *testing.T) {
	flow := consentRead(t, consentSourceFiles[1])
	for line, count := range map[string]int{
		"connector.signNetworkConsent(walletId: walletId, challenge: challenge)":                  1,
		"guard proof.message == challenge.message, proof.address == challenge.coldkeySs58 else {": 1,
		"client.submit(": 1,
		"try await client.submit(coldkeySs58: proof.address, message: proof.message, signature: proof.signature)": 1,
	} {
		if got := strings.Count(flow, line); got != count {
			t.Errorf("the flow has %d of %q, want %d", got, line, count)
		}
	}
	if strings.Index(flow, "guard proof.message == challenge.message") > strings.Index(flow, "client.submit(") {
		t.Error("the flow submits before it checks the proof's message")
	}

	connector := consentRead(t, "app/network/Shared/Bittensor/BittensorWalletConnector.swift")
	sign := consentDeclaration(t, connector, "    ", "func signNetworkConsent(walletId: String, challenge: SdkSnNetworkConsentChallengeResult)")
	for _, line := range []string{
		"purpose: SdkBittensorWalletPurposeConsent, expectedAddress: challenge.coldkeySs58",
		"try session.setNetworkConsentChallenge(challenge, nowMillis: now())",
	} {
		if !strings.Contains(sign, line) {
			t.Errorf("signNetworkConsent does not hand the challenge over as issued: %q", line)
		}
	}
	if !strings.Contains(connector, "try session.setNetworkConsentChallenge(result, nowMillis: nowMillis)") {
		t.Error("the SDK session adapter does not pass the challenge through")
	}

	submits := 0
	err := filepath.Walk(filepath.Join(consentRoot(t), "app/network"), func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if n := strings.Count(string(data), "snNetworkConsentSubmit("); n > 0 {
			if filepath.Base(path) != "NetworkConsentClient.swift" {
				t.Errorf("%s submits a consent", path)
			}
			submits += n
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if submits != 1 {
		t.Errorf("the app submits a consent from %d places, want 1", submits)
	}
}
