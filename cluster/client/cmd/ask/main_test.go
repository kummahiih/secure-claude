package main

import (
	"bytes"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

func TestRunAskUsage(t *testing.T) {
	var out bytes.Buffer
	err := runAsk(nil, &out, "unused", "unused", "unused")
	if err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("expected usage error, got %v", err)
	}
	err = runAsk([]string{"only-model"}, &out, "unused", "unused", "unused")
	if err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("expected usage error for single arg, got %v", err)
	}
}

func TestRunAskMissingTokens(t *testing.T) {
	var out bytes.Buffer
	missing := filepath.Join(t.TempDir(), "nope.env")
	err := runAsk([]string{"claude", "hello"}, &out, missing, "unused", "https://example.invalid")
	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("expected missing tokens error, got %v", err)
	}
}

func TestRunAskSuccess(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer sekret" {
			t.Errorf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"response":"hi there","other":1}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	tokensPath := writeFile(t, dir, "tokens.env", "CLAUDE_API_TOKEN=sekret\n")
	caPath := writeFile(t, dir, "ca.pem", string(pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: srv.Certificate().Raw,
	})))

	var out bytes.Buffer
	if err := runAsk([]string{"claude", "hello?"}, &out, tokensPath, caPath, srv.URL); err != nil {
		t.Fatalf("runAsk: %v", err)
	}
	got := strings.TrimSpace(out.String())
	if got != "hi there" {
		t.Errorf("stdout = %q; want %q", got, "hi there")
	}
}

func TestRunAskRaw(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"response":"hi","n":1}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	tokensPath := writeFile(t, dir, "tokens.env", "CLAUDE_API_TOKEN=sekret\n")
	caPath := writeFile(t, dir, "ca.pem", string(pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: srv.Certificate().Raw,
	})))

	var out bytes.Buffer
	if err := runAsk([]string{"claude", "hi?", "--raw"}, &out, tokensPath, caPath, srv.URL); err != nil {
		t.Fatalf("runAsk raw: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, "\"response\"") || !strings.Contains(s, "  ") {
		t.Errorf("expected indented JSON with response field; got %q", s)
	}
	if !strings.Contains(s, "\"n\"") {
		t.Errorf("expected other fields preserved; got %q", s)
	}
}
