package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// The v1 claim dialog's gas is Swift that cannot be compiled here, so these
// tests read its sources (VERSION2-LAUNCH.md §2.6). On runtime 478 the SDK
// signs every v1 claim with its estimate plus a quarter and at least 2,700,000
// gas, below which the vault accepts a claim but defers its payment, and sends
// it only when the gas key holds that limit at 1.1 × the gas price, else the
// claim fails needs_gas. The dialog's per-claim reserve is what its top-up
// asks for and what Claim waits for, so it must cover that.

// the SDK's least v1 claim gas limit (sdk/sn_claims.go snClaimGasFloor) at its
// legacy price, 1.1 × a 5 gwei gas price, in TAO: 0.01485
const v1GasFloorTao = 2_700_000 * 1.1 * 5e9 / 1e18

func v1GasRead(t *testing.T, rel string) string {
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

// the TAO a static let of the view model holds
func v1GasConstant(t *testing.T, source string, name string) float64 {
	t.Helper()
	match := regexp.MustCompile(`\n    static let ` + name + ` = ([0-9.]+)\n`).FindStringSubmatch(source)
	if match == nil {
		t.Fatalf("no static let %s", name)
	}
	value, err := strconv.ParseFloat(match[1], 64)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

// VERSION2-LAUNCH.md §2.6: the top-up asks for 0.02 TAO for each claimable
// epoch, a v2 claim's reserve, which covers the SDK's v1 floor up to about
// 6.7 gwei
func TestV1ClaimGasTopUpCoversTheSdkFloor(t *testing.T) {
	model := v1GasRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift")
	perClaim := v1GasConstant(t, model, "gasTaoPerClaim")
	if perClaim != 0.02 {
		t.Errorf("gasTaoPerClaim = %v, want 0.02", perClaim)
	}
	if ledger := v1GasConstant(t, model, "ledgerGasTaoPerClaim"); perClaim != ledger {
		t.Errorf("gasTaoPerClaim = %v, a v2 claim's is %v", perClaim, ledger)
	}
	if perClaim < v1GasFloorTao {
		t.Errorf("gasTaoPerClaim = %v is below the SDK's v1 floor, %v TAO at 5 gwei", perClaim, v1GasFloorTao)
	}
	if !strings.Contains(model, "Self.gasTaoPerClaim * Double(max(1, claimableClaims.count))") {
		t.Error("the top-up is not the reserve for each claimable epoch")
	}
	sheet := v1GasRead(t, "app/network/Main/Account/Earnings/ClaimAlphaSheet.swift")
	for _, line := range []string{
		"gasNeededTao: viewModel.gasNeededTao,",
		`Text("Send about \(String(format: "%.4f", gasNeededTao)) TAO to \(gasKey.mirrorSs58) to cover gas.")`,
	} {
		if !strings.Contains(sheet, line) {
			t.Errorf("the claim dialog does not show the top-up: %s", line)
		}
	}
}

// VERSION2-LAUNCH.md §2.6: Claim waits until the gas key holds the top-up, so
// the dialog never offers a claim the SDK refuses as needs_gas
func TestV1ClaimWaitsForTheGasTopUp(t *testing.T) {
	model := v1GasRead(t, "app/network/Main/Account/Earnings/EarningsViewModel.swift")
	if !strings.Contains(model, "    var needsGas: Bool {\n        (gasTao ?? 0) < gasNeededTao\n    }\n") {
		t.Error("needsGas is not a gas key short of the top-up")
	}
	sheet := v1GasRead(t, "app/network/Main/Account/Earnings/ClaimAlphaSheet.swift")
	for _, line := range []string{
		"needsGas: viewModel.needsGas,",
		"enabled: claimableCount > 0 && !viewModel.needsGas && !viewModel.isClaiming,",
	} {
		if !strings.Contains(sheet, line) {
			t.Errorf("Claim does not wait for the top-up: %s", line)
		}
	}
}
