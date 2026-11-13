package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// Owner, 2026-11-13: a failed Solana wallet sign-in shows the same specific
// message on every app; the sdk (SolanaWalletFailureFor) classifies the
// failure and the app only displays the message for its key. Before, the
// Apple app's own words for four bridge codes were shown nowhere: signing in
// said "There was an error logging in" or nothing, and adding a sign-in method
// said nothing (on macOS it never took the wallet's hand-back at all). The
// app's Swift cannot be compiled here, so these tests read its sources. They
// check these things:
//   - the wallet provider reads every failure through the sdk, in the ur.io
//     bridge page's scheme on macOS and the wallet apps' on iOS, and keeps no
//     words of its own for a code;
//   - each of the sdk's seven message keys has its own case, whose literal is
//     the localizations store's apple source for that key;
//   - signing in, its sheet and adding a sign-in method show the failure's
//     message, and the add sheet takes its hand-backs on iOS and macOS alike.

// A source, by its path from the repository root.
func solanaSignInRead(t *testing.T, rel string) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(source), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

const solanaSignInProviderPath = "app/network/Shared/ViewModels/ConnectWalletProviderViewModel.swift"

// Every failure the wallet provider hands out, handed back or its own.
func TestSolanaSignInFailuresReadTheSdk(t *testing.T) {
	provider := solanaSignInRead(t, solanaSignInProviderPath)
	for _, line := range []string{
		"let classified = SdkSolanaWalletFailureFor(source, code, walletId)",
		// the scheme of a hand-back's code follows how openURL hands off
		"#if canImport(UIKit)\n        walletReturnSource = SdkSolanaWalletFailureSourceWalletApp\n        #else\n        walletReturnSource = SdkSolanaWalletFailureSourceBridge\n        #endif",
		"let failure = SolanaWalletFailure(source: walletReturnSource, code: errorCode, provider: provider)",
		// a wallet that would not open, and a hand-back that cannot be read
		"onOpenFailed(.app(SdkSolanaWalletFailureWalletAppNotFound, provider: provider))",
		"return .app(SdkSolanaWalletFailureWallet, provider: provider)",
		"onError: ((_ failure: SolanaWalletFailure) -> Void)? = nil",
	} {
		if !strings.Contains(provider, line) {
			t.Errorf("the wallet provider lacks %q", line)
		}
	}
	// the codes are the sdk's to read, and the wallet's own text is not shown
	for _, token := range []string{"SolanaWalletReturnError", "SdkSolanaWalletBridgeError", "walletError(", "NSLocalizedDescriptionKey"} {
		if strings.Contains(provider, token) {
			t.Errorf("the wallet provider still has %s", token)
		}
	}
}

// The case of each sdk message key, and its literal: the store's apple source
// with a Swift interpolation for its argument.
func TestSolanaSignInFailureMessagesAreTheStoreSources(t *testing.T) {
	provider := solanaSignInRead(t, solanaSignInProviderPath)
	start := strings.Index(provider, "static func message(messageKey: String, walletName: String) -> String {")
	if start < 0 {
		t.Fatal("no message switch")
	}
	body := provider[start:]
	// the switch's cases, to the end of the function
	end := strings.Index(body, "\n    }\n")
	if end < 0 {
		t.Fatal("the message switch does not end")
	}
	body = body[:end]
	literal := regexp.MustCompile(`String\(localized: "((?:[^"\\]|\\.)*)"\)`)
	interpolation := regexp.MustCompile(`\\\([^()]*\)`)
	for _, c := range []struct {
		key    string
		source string
	}{
		{"SdkSolanaWalletFailureMessageUserRejected", "The request was declined in your wallet. Start again and approve it to continue."},
		{"SdkSolanaWalletFailureMessageNoWallet", "No Solana wallets were found installed on this device. Please install a wallet and try again."},
		{"SdkSolanaWalletFailureMessageWalletAppNotFound", "Couldn't open wallet. Please install it and try again."},
		{"SdkSolanaWalletFailureMessageExtensionNotFound", "The %@ extension was not found in this browser. Install it, then try again."},
		{"SdkSolanaWalletFailureMessageNoAccount", "Your %@ wallet has no account to sign with. Add or connect an account in the wallet, then try again."},
		{"SdkSolanaWalletFailureMessageSessionNotFound", "The wallet connection wasn't found in this browser. Start again to reconnect your wallet."},
		{"SdkSolanaWalletFailureMessageWallet", "Your %@ wallet couldn't finish the request. Check the wallet, then try again."},
	} {
		label := "case " + c.key + ":"
		if strings.Count(body, label) != 1 {
			t.Errorf("%d cases for %s, want 1", strings.Count(body, label), c.key)
			continue
		}
		rest := body[strings.Index(body, label)+len(label):]
		// the generic failure falls through to the default, a key this build
		// does not know
		if strings.HasPrefix(strings.TrimSpace(rest), "fallthrough") {
			rest = rest[strings.Index(rest, "default:"):]
		}
		match := literal.FindStringSubmatch(rest)
		if match == nil {
			t.Errorf("%s has no literal", c.key)
			continue
		}
		if got := interpolation.ReplaceAllString(match[1], "%@"); got != c.source {
			t.Errorf("%s reads %q, want the store's %q", c.key, got, c.source)
		}
	}
}

// The text before `at` opens as many conditional blocks as it closes.
func solanaSignInUnconditional(source string, at int) bool {
	before := source[:at]
	return strings.Count(before, "#if ") == strings.Count(before, "#endif")
}

// Signing in, the second signature that creates a network, the sign-in
// sheet, and adding a sign-in method.
func TestSolanaSignInCallersShowTheFailure(t *testing.T) {
	login := solanaSignInRead(t, "app/network/Authenticate/LoginInitial/LoginInitialView.swift")
	for _, line := range []string{
		// a sign step's failure, a connect step's, and the sheet's own
		"viewModel.failSolanaAttempt(failure, request: attempt.request)",
		"failSolanaSignIn(failure)",
		"onFailure: failSolanaSignIn",
		// the iOS tile without a wallet app
		"Text(SolanaWalletFailure.app(SdkSolanaWalletFailureNoWallet, provider: nil).message)",
	} {
		if !strings.Contains(login, line) {
			t.Errorf("signing in lacks %q", line)
		}
	}
	model := solanaSignInRead(t, "app/network/Authenticate/LoginInitial/LoginInitialViewModel.swift")
	if !strings.Contains(model, "setLoginErrorMessage(failure.message)") {
		t.Error("a failed Solana sign-in does not show the failure's message")
	}

	sheet := solanaSignInRead(t, "app/network/Shared/Views/SolanaSignMessageSheet.swift")
	for _, wallet := range []string{"Phantom", "Solflare"} {
		call := "connectWalletProviderViewModel.connect" + wallet + "Wallet("
		if strings.Count(sheet, call) != 1 || !strings.Contains(sheet, call+"onOpenFailed: onFailure)") {
			t.Errorf("the sign-in sheet connects %s without reporting its failure", wallet)
		}
	}
	if strings.Count(sheet, "onOpenFailed: signFailed") != 2 || strings.Contains(sheet, "snackbarManager") {
		t.Error("the sign-in sheet's sign step does not report its failure to the sheet's owner")
	}

	add := solanaSignInRead(t, "app/network/Main/Account/Settings/AddAuthSheet.swift")
	at := strings.Index(add, "handleSolanaWalletReturn(url)")
	if at < 0 || !solanaSignInUnconditional(add, at) {
		t.Error("the add sheet does not take its Solana hand-backs on every platform")
	}
	for _, line := range []string{
		"addError = failure.message",
		"vm.handleDeepLink(url, onError: failWallet)",
		"connectPhantomWallet(onOpenFailed: failWallet)",
		"signMessageSolflare(message: message, onOpenFailed: failWallet)",
	} {
		if !strings.Contains(add, line) {
			t.Errorf("adding a sign-in method lacks %q", line)
		}
	}
	for _, rel := range []string{
		"app/network/Main/Account/Settings/AddAuthSheet.swift",
		"app/network/Main/Account/Settings/SettingsView.swift",
		"app/network/Shared/Views/SolanaSignMessageSheet.swift",
	} {
		source := solanaSignInRead(t, rel)
		for _, token := range []string{
			// the English the add sheet showed
			"Could not open wallet. Please install it and try again.",
			"Failed to start wallet signing",
			`"Wallet not connected"`,
			// Settings' iOS-only route to the add sheet
			"pendingAddAuthSignatureHandler",
			"handleWalletDeepLink",
		} {
			if strings.Contains(source, token) {
				t.Errorf("%s still has %s", rel, token)
			}
		}
	}
}
