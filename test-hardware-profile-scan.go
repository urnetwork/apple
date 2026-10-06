// SPDX-License-Identifier: MPL-2.0

// Audit direct Swift profile operations without treating formatting or literal
// text as executable code. This is a lexical boundary, not Swift type inference.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// Inventory output is bounded independently of the source-size budget.
type profileScanBuffer struct {
	buffer bytes.Buffer
	limit  int
}

// Reject partial output instead of mistaking truncation for a complete scan.
func (self *profileScanBuffer) Write(data []byte) (int, error) {
	if self.buffer.Len()+len(data) > self.limit {
		return 0, fmt.Errorf("inventory output limit exceeded")
	}
	return self.buffer.Write(data)
}

// Token positions retain source diagnostics after comments/literals are skipped.
type profileScanToken struct {
	text string
	line int
}

// One file owns its lexical cursor and nesting budget; no mutable global state.
type profileScanLexer struct {
	ctx    context.Context
	source string
	offset int
	line   int
	tokens []profileScanToken
}

// Advance over a known byte span while preserving one-based diagnostic lines.
func (self *profileScanLexer) advance(count int) {
	for index := self.offset; index < self.offset+count; index++ {
		if self.source[index] == '\n' || self.source[index] == '\r' &&
			(index+1 == len(self.source) || self.source[index+1] != '\n') {
			self.line++
		}
	}
	self.offset += count
}

// Emit literal boundaries as well as code so text cannot join adjacent tokens.
func (self *profileScanLexer) token(text string) {
	self.tokens = append(self.tokens, profileScanToken{text: text, line: self.line})
}

// Swift permits Unicode identifiers. ASCII punctuation still separates them;
// UTF-8 validity is checked before lexing, so a byte run cannot conceal a dot.
func profileScanIdentifier(value byte) bool {
	return value >= 0x80 || value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' || value == '_' || value == '$'
}

// Scan code recursively only at executable string interpolations. Parentheses
// within the interpolation are balanced independently of nested strings/comments.
func (self *profileScanLexer) code(interpolation bool, depth int) error {
	if depth > 256 {
		return fmt.Errorf("interpolation nesting limit exceeded")
	}
	parentheses := 0
	for self.offset < len(self.source) {
		if err := self.ctx.Err(); err != nil {
			return err
		}
		if len(self.tokens) > 1024*1024 {
			return fmt.Errorf("source token limit exceeded")
		}
		rest := self.source[self.offset:]
		switch {
		case strings.ContainsRune(" \t\r\n\v\f", rune(rest[0])):
			self.advance(1)
		case strings.HasPrefix(rest, "//"):
			end := strings.IndexAny(rest, "\r\n")
			if end < 0 {
				end = len(rest)
			}
			self.advance(end)
		case strings.HasPrefix(rest, "/*"):
			self.advance(2)
			nesting := 1
			for nesting != 0 {
				if err := self.ctx.Err(); err != nil {
					return err
				}
				if self.offset == len(self.source) {
					return fmt.Errorf("unterminated block comment")
				}
				switch {
				case strings.HasPrefix(self.source[self.offset:], "/*"):
					nesting++
					if nesting > 256 {
						return fmt.Errorf("comment nesting limit exceeded")
					}
					self.advance(2)
				case strings.HasPrefix(self.source[self.offset:], "*/"):
					nesting--
					self.advance(2)
				default:
					self.advance(1)
				}
			}
		case rest[0] == '`':
			end := strings.IndexByte(rest[1:], '`')
			if end < 0 {
				return fmt.Errorf("unterminated escaped identifier")
			}
			name := rest[1 : end+1]
			if name == "" {
				return fmt.Errorf("empty escaped identifier")
			}
			for index := range len(name) {
				if !profileScanIdentifier(name[index]) {
					return fmt.Errorf("unsupported escaped identifier")
				}
			}
			self.token(name)
			self.advance(end + 2)
		case rest[0] == '"' || rest[0] == '#':
			hashes := 0
			for hashes < len(rest) && rest[hashes] == '#' {
				hashes++
			}
			if hashes < len(rest) && rest[hashes] == '"' {
				if err := self.literal(hashes, depth); err != nil {
					return err
				}
			} else if hashes < len(rest) && rest[hashes] == '/' {
				return fmt.Errorf("unsupported regex literal")
			} else {
				self.token(rest[:1])
				self.advance(1)
			}
		case profileScanIdentifier(rest[0]):
			end := 1
			for end < len(rest) && profileScanIdentifier(rest[end]) {
				end++
			}
			self.token(rest[:end])
			self.advance(end)
		default:
			// Reject ambiguous slash literals before their quotes or comment
			// markers can hide code. Division binds to a same-line operand,
			// or may continue across lines with whitespace on both sides.
			if rest[0] == '/' {
				previous := ""
				previousLine := 0
				if len(self.tokens) != 0 {
					previous = self.tokens[len(self.tokens)-1].text
					previousLine = self.tokens[len(self.tokens)-1].line
				}
				leftSpace := self.offset == 0 || strings.ContainsRune(" \t\r\n", rune(self.source[self.offset-1]))
				rightSpace := len(rest) > 1 && strings.ContainsRune(" \t\r\n", rune(rest[1]))
				keyword := strings.Contains(" return throw try await yield consume copy case in where if while guard switch let var else for do catch defer repeat as is ", " "+previous+" ")
				if previous == "" || keyword || previousLine != self.line && !leftSpace || leftSpace != rightSpace ||
					!(profileScanIdentifier(previous[0]) || previous == ")" || previous == "]") {
					return fmt.Errorf("unsupported regex literal or prefix slash")
				}
			}
			self.token(rest[:1])
			self.advance(1)
			if interpolation {
				switch rest[0] {
				case '(':
					parentheses++
				case ')':
					if parentheses == 0 {
						return nil
					}
					parentheses--
				}
			}
		}
	}
	if interpolation {
		return fmt.Errorf("unterminated string interpolation")
	}
	return nil
}

// Raw delimiters require the same hash count for closing/escaping. A literal's
// text is inert, but each correctly escaped interpolation re-enters the lexer.
func (self *profileScanLexer) literal(hashes int, depth int) error {
	quotes := 1
	if strings.HasPrefix(self.source[self.offset+hashes:], `"""`) {
		quotes = 3
	}
	closing := strings.Repeat(`"`, quotes) + strings.Repeat("#", hashes)
	escape := `\` + strings.Repeat("#", hashes)
	self.token("<literal>")
	self.advance(hashes + quotes)
	for self.offset < len(self.source) {
		if err := self.ctx.Err(); err != nil {
			return err
		}
		rest := self.source[self.offset:]
		switch {
		case strings.HasPrefix(rest, closing):
			self.advance(len(closing))
			self.token("<literal>")
			return nil
		case strings.HasPrefix(rest, escape):
			self.advance(len(escape))
			if self.offset == len(self.source) {
				return fmt.Errorf("unterminated string escape")
			}
			if self.source[self.offset] == '(' {
				self.token("(")
				self.advance(1)
				if err := self.code(true, depth+1); err != nil {
					return err
				}
			} else {
				self.advance(1)
			}
		case quotes == 1 && (rest[0] == '\n' || rest[0] == '\r'):
			return fmt.Errorf("newline in single-line string")
		default:
			self.advance(1)
		}
	}
	return fmt.Errorf("unterminated string literal")
}

// Only the literal unqualified gateway receiver is exempt. Subscripts, calls,
// parentheses, force/optional chaining and similarly named receivers are raw.
func profileScanForbidden(tokens []profileScanToken, index int) bool {
	name := tokens[index].text
	if name == "NEVPNManager" {
		return true
	}
	if name == "NETunnelProviderManager" || name == "NETransparentProxyManager" || name == "NEAppProxyProviderManager" {
		if index+1 < len(tokens) && tokens[index+1].text == "(" {
			return true
		}
		if index+2 < len(tokens) && tokens[index+1].text == "." && tokens[index+2].text == "init" {
			return true
		}
	}
	switch name {
	case "saveToPreferences", "loadFromPreferences", "removeFromPreferences", "startVPNTunnel", "stopVPNTunnel", "loadAllFromPreferences":
		if index == 0 || tokens[index-1].text != "." {
			return false
		}
		return !(index >= 2 && tokens[index-2].text == "VPNProfileSystem" &&
			(index < 3 || tokens[index-3].text != "."))
	default:
		return false
	}
}

// Preserve rg's original Swift-file selection and no-match status while owning
// its lifetime and rejecting malformed, partial or out-of-scope inventory.
func profileScanInventory(ctx context.Context, root string) ([]string, error) {
	output := &profileScanBuffer{limit: 8 * 1024 * 1024}
	errors := &profileScanBuffer{limit: 1024 * 1024}
	command := exec.CommandContext(ctx, "rg", "--files", "-0", "--glob", "*.swift", root)
	command.Stdout, command.Stderr = output, errors
	// rg is a single owned process. Do not detach it from the timeout group:
	// outer termination must reach the compiler, CLI and inventory together.
	command.WaitDelay = 2 * time.Second
	if err := command.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); !ok || exitError.ExitCode() != 1 || output.buffer.Len() != 0 {
			return nil, fmt.Errorf("Swift inventory failed: %w: %s", err, errors.buffer.String())
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if output.buffer.Len() == 0 {
		return nil, nil
	}
	if output.buffer.Bytes()[output.buffer.Len()-1] != 0 {
		return nil, fmt.Errorf("incomplete Swift inventory")
	}
	paths := strings.Split(string(output.buffer.Bytes()[:output.buffer.Len()-1]), "\x00")
	if len(paths) > 20000 {
		return nil, fmt.Errorf("Swift file-count limit exceeded")
	}
	for _, path := range paths {
		if !filepath.IsAbs(path) || !strings.HasPrefix(filepath.Clean(path), root+string(os.PathSeparator)) ||
			filepath.Ext(path) != ".swift" {
			return nil, fmt.Errorf("out-of-scope Swift inventory entry: %q", path)
		}
	}
	return paths, nil
}

// Emit matches only after every selected file has been read and tokenized.
// A failed observation cannot leave callers with an apparently complete audit.
func profileScan(ctx context.Context, root string, gateway string) ([]string, error) {
	info, err := os.Stat(root)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("source root is not a directory")
	}
	paths, err := profileScanInventory(ctx, root)
	if err != nil {
		return nil, err
	}
	remaining := 128 * 1024 * 1024
	matches := []string{}
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		data, err := func() ([]byte, error) {
			info, err := os.Lstat(path)
			if err != nil {
				return nil, err
			}
			if !info.Mode().IsRegular() {
				return nil, fmt.Errorf("source is not a regular file")
			}
			if info.Size() > 16*1024*1024 {
				return nil, fmt.Errorf("source file byte limit exceeded")
			}
			file, err := os.Open(path)
			if err != nil {
				return nil, err
			}
			defer file.Close()
			return io.ReadAll(io.LimitReader(file, 16*1024*1024+1))
		}()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		remaining -= len(data)
		if len(data) > 16*1024*1024 || remaining < 0 {
			return nil, fmt.Errorf("source byte limit exceeded")
		}
		if !utf8.Valid(data) {
			return nil, fmt.Errorf("%s: invalid UTF-8 source", path)
		}
		lexer := &profileScanLexer{ctx: ctx, source: string(data), line: 1}
		if err := lexer.code(false, 0); err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, lexer.line, err)
		}
		if filepath.Clean(path) == gateway {
			continue
		}
		for index, token := range lexer.tokens {
			if profileScanForbidden(lexer.tokens, index) {
				matches = append(matches, fmt.Sprintf("%s:%d: unguarded profile operation %s", path, token.line, token.text))
			}
		}
	}
	return matches, nil
}

// The shell owns the compile-inclusive 90-second deadline; this invocation owns
// a shorter scan deadline and joins its inventory child before returning.
func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "profile source scan: expected source-root and exact-gateway")
		os.Exit(2)
	}
	root, rootError := filepath.Abs(os.Args[1])
	gateway, gatewayError := filepath.Abs(os.Args[2])
	if rootError != nil || gatewayError != nil {
		fmt.Fprintln(os.Stderr, "profile source scan: invalid source path")
		os.Exit(2)
	}
	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithTimeout(signalContext, 60*time.Second)
	matches, err := profileScan(ctx, root, gateway)
	cancel()
	stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, "profile source scan:", err)
		os.Exit(2)
	}
	for _, match := range matches {
		fmt.Println(match)
	}
}
