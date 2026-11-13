package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// USDC provider payouts ended on 2026-11-12, and the owner closed USDC out on
// 2026-11-13 (support inbox 8258): providers are paid in SN25α to a Bittensor
// coldkey only. The app's Swift cannot be compiled here, so these tests read
// its sources. They check these things:
//   - no Swift source calls the sdk's payout-wallet api (set and get the
//     payout wallet, the wallet view controller's payout wallet, the next
//     payout date, an external wallet, the pending USDC payout), which the sdk
//     drops;
//   - the Earnings screen keeps no USDC payout surface: no Connect Solana
//     wallet entry, no Solana payout wallet card or its removal, no final USDC
//     payout line.
// Customer payments in USDC (the direct-download build's crypto checkout) and
// signing in with a Solana wallet are not payouts and are not checked here.

func usdcClosedRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

// Every Swift source under app, the app's targets and their tests, keyed by
// its path from the repository root.
func usdcClosedSwiftSources(t *testing.T) map[string]string {
	t.Helper()
	root := usdcClosedRoot(t)
	sources := map[string]string{}
	err := filepath.Walk(filepath.Join(root, "app"), func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".swift") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		sources[filepath.ToSlash(rel)] = string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// premise: the walk found the app
	if _, ok := sources["app/network/Main/Account/Earnings/EarningsView.swift"]; !ok {
		t.Fatal("the Earnings screen's source is not under app/network")
	}
	return sources
}

// The paths of the sources that hold token, sorted.
func usdcClosedHolders(sources map[string]string, token string) []string {
	holders := []string{}
	for rel, source := range sources {
		if strings.Contains(source, token) {
			holders = append(holders, rel)
		}
	}
	sort.Strings(holders)
	return holders
}

// The sdk's payout-wallet api, as gomobile names it in Swift.
func TestUsdcPayoutsClosedNoSdkPayoutWalletApi(t *testing.T) {
	sources := usdcClosedSwiftSources(t)
	for _, token := range []string{
		"SdkSetPayoutWallet",
		"SdkGetPayoutWallet",
		".setPayoutWallet(",
		".getPayoutWallet(",
		"fetchPayoutWallet",
		"IsPollingPayoutWallet",
		"NextPayoutDate",
		"addExternalWallet",
		"pendingPayoutUsdNanoCents",
	} {
		if holders := usdcClosedHolders(sources, token); len(holders) != 0 {
			t.Errorf("%s still in %v", token, holders)
		}
	}
}

// The Earnings screen's USDC payout surface: its types, and the literals of
// its entry, card, removal and waiting line.
func TestUsdcPayoutsClosedNoPayoutWalletSurface(t *testing.T) {
	root := usdcClosedRoot(t)
	if _, err := os.Stat(filepath.Join(root, "app/network/Main/Account/Earnings/Usdc")); !os.IsNotExist(err) {
		t.Errorf("the USDC payout wallet's folder is still there (%v)", err)
	}
	sources := usdcClosedSwiftSources(t)
	for _, token := range []string{
		"UsdcWallet",
		"UsdcPayment",
		"UsdcFormat",
		"ConnectSolanaWallet",
		"SolanaWalletCard",
		"PayoutWalletTag",
		`"Connect Solana wallet"`,
		"Final USDC payout",
		"USDC payouts continue",
		"USDC payouts move to",
		`"Payout wallet updated"`,
		"Payouts now go to",
		"Solana USDC",
	} {
		if holders := usdcClosedHolders(sources, token); len(holders) != 0 {
			t.Errorf("%s still in %v", token, holders)
		}
	}
}
