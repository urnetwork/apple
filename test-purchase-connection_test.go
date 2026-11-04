package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// What a purchase does with the connection (ConnectViewModel.purchaseAroundConnection,
// which every surface's purchase goes through by ConnectionAwareSubscriptionStore) is
// Swift that can't be compiled here, so these tests read its sources. The Swift unit
// tests (PurchaseAroundConnectionTests, OutOfBalanceDisconnectFirstTests) run the
// behaviour. These check:
//   - only the Mac App Store build drops the connection for a purchase. The direct
//     download pays on a page that loads after the purchase call has returned, so a
//     drop around the call ended before the page asked for anything: it gained
//     nothing, left the traffic unprotected for a moment, and its notice's Cancel
//     stopped the purchase.

func purchaseRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the Apple source")
	}
	return filepath.Dir(source)
}

func purchaseRead(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(purchaseRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// The code of a Swift source with its comments gone: a word in a comment is not
// code. Lines that start a comment go, and what follows " // " on a line of code.
func purchaseCode(source string) string {
	var lines []string
	for _, line := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "*") || strings.HasPrefix(trimmed, "/*") {
			continue
		}
		if i := strings.Index(line, " // "); i >= 0 {
			line = line[:i]
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// The code with every run of white space one space, to compare a block as written.
func purchaseSquash(code string) string {
	return strings.Join(strings.Fields(code), " ")
}

// The block that opens with the first `{` of `start`, to its matching `}`.
func purchaseBody(t *testing.T, code string, start string) string {
	t.Helper()
	from := strings.Index(code, start)
	if from < 0 {
		t.Fatalf("no %q", start)
	}
	open := strings.Index(code[from:], "{")
	if open < 0 {
		t.Fatalf("%q opens no block", start)
	}
	depth := 0
	for i := from + open; i < len(code); i += 1 {
		switch code[i] {
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				return code[from+open : i+1]
			}
		}
	}
	t.Fatalf("%q is not closed", start)
	return ""
}

// The Swift under app/network, by path, with its comments gone.
func purchaseAppSources(t *testing.T) map[string]string {
	t.Helper()
	root := filepath.Join(purchaseRoot(t), "app/network")
	sources := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".swift") {
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
		sources[rel] = purchaseCode(string(data))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) < 100 {
		t.Fatalf("CONTROL FAILED: read %d Swift sources", len(sources))
	}
	return sources
}

func TestPurchaseCodeLeavesTheCommentsOut(t *testing.T) {
	code := purchaseCode("// purchaseDropsConnection = true\n/**\n * purchaseDropsConnection = true\n */\nlet a = 1 // purchaseDropsConnection = true\nmodel.disconnect()")
	if strings.Contains(code, "purchaseDropsConnection") || !strings.Contains(code, "let a = 1") || !strings.Contains(code, "model.disconnect()") {
		t.Fatalf("the scan reads %q", code)
	}
	body := purchaseBody(t, "func f() { if a { b() } }\nfunc g() {}", "func f() {")
	if body != "{ if a { b() } }" {
		t.Fatalf("the block is %q", body)
	}
}

// Only the Mac App Store build drops the connection for a purchase, and the view
// model drops as its build does: the decision is the build's, not the platform's.
func TestOnlyTheMacAppStoreBuildDropsTheConnectionForAPurchase(t *testing.T) {
	distribution := purchaseCode(purchaseRead(t, "app/network/Shared/Billing/BillingDistribution.swift"))
	if !strings.Contains(distribution, "var purchaseDropsConnection: Bool {") {
		t.Error("BillingDistribution does not say which build drops the connection for a purchase")
	} else if drops := purchaseSquash(purchaseBody(t, distribution, "var purchaseDropsConnection: Bool {")); drops != "{ #if os(macOS) return self == .appStore #else return false #endif }" {
		t.Errorf("a purchase drops the connection on more than the Mac App Store build: %s", drops)
	}

	model := purchaseCode(purchaseRead(t, "app/network/Shared/ViewModels/ConnectViewModel.swift"))
	if strings.Count(model, "var purchaseDropsConnection = BillingDistribution.current.purchaseDropsConnection\n") != 1 {
		t.Error("the view model does not drop the connection as its build does")
	}
	if regexp.MustCompile(`purchaseDropsConnection\s*=\s*(true|false)`).MatchString(model) {
		t.Error("the view model fixes the drop for a whole platform, the direct download included")
	}
	flow := purchaseSquash(purchaseBody(t, model, "func purchaseAroundConnection(_ purchase: () async -> Void) async {"))
	if !strings.HasPrefix(flow, "{ guard purchaseDropsConnection else { await purchase() return }") {
		t.Errorf("a build that keeps the connection does not buy at once, with no notice and no disconnect: %s", flow)
	}

	// only the declaration sets it in the app; the tests stand in for the build
	assignment := regexp.MustCompile(`purchaseDropsConnection\s*=[^=]`)
	for path, code := range purchaseAppSources(t) {
		n := len(assignment.FindAllString(code, -1))
		if path == "Shared/ViewModels/ConnectViewModel.swift" {
			n -= 1
		}
		if n > 0 {
			t.Errorf("%s sets purchaseDropsConnection", path)
		}
	}
}
