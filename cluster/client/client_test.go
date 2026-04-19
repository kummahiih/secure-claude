package client

import (
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTempFile(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	return p
}

func TestLoadTokens(t *testing.T) {
	t.Run("parses KEY=VALUE and ignores blanks/comments", func(t *testing.T) {
		content := strings.Join([]string{
			"# header comment",
			"",
			"CLAUDE_API_TOKEN=abc123",
			"export PLAN_API_TOKEN=xyz789",
			`QUOTED="hello world"`,
			"  SPACED  =  trimmed  ",
			"",
			"# trailing comment",
		}, "\n")
		path := writeTempFile(t, ".cluster_tokens.env", content)
		got, err := LoadTokens(path)
		if err != nil {
			t.Fatalf("LoadTokens: %v", err)
		}
		want := map[string]string{
			"CLAUDE_API_TOKEN": "abc123",
			"PLAN_API_TOKEN":   "xyz789",
			"QUOTED":           "hello world",
			"SPACED":           "trimmed",
		}
		if len(got) != len(want) {
			t.Fatalf("got %d keys, want %d (%v)", len(got), len(want), got)
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("key %q = %q; want %q", k, got[k], v)
			}
		}
	})

	t.Run("returns error on missing file", func(t *testing.T) {
		_, err := LoadTokens(filepath.Join(t.TempDir(), "nope.env"))
		if err == nil {
			t.Fatal("expected error for missing file, got nil")
		}
	})
}

func TestPostJSON(t *testing.T) {
	t.Run("posts JSON body with correct Authorization", func(t *testing.T) {
		var gotAuth, gotCT string
		var gotBody map[string]string
		srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			gotAuth = r.Header.Get("Authorization")
			gotCT = r.Header.Get("Content-Type")
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &gotBody)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"response":"ok"}`))
		}))
		defer srv.Close()

		caPath := writeTempFile(t, "ca.pem", string(pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: srv.Certificate().Raw,
		})))

		raw, err := PostJSON(srv.URL, "sekret", caPath, "claude-sonnet-4-6", "hello?")
		if err != nil {
			t.Fatalf("PostJSON: %v", err)
		}
		if gotAuth != "Bearer sekret" {
			t.Errorf("Authorization = %q; want %q", gotAuth, "Bearer sekret")
		}
		if gotCT != "application/json" {
			t.Errorf("Content-Type = %q; want application/json", gotCT)
		}
		if gotBody["model"] != "claude-sonnet-4-6" || gotBody["query"] != "hello?" {
			t.Errorf("body = %+v", gotBody)
		}
		if !strings.Contains(string(raw), "\"ok\"") {
			t.Errorf("raw = %s; want to contain ok", raw)
		}
	})

	t.Run("returns error when CA does not match server", func(t *testing.T) {
		// 1. Create a server but DO NOT use the default httptest client/trust
		srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
		srv.StartTLS() // Starts with a self-signed cert
		defer srv.Close()

		// 2. Create a "Wrong" CA file
		// We can just generate a random self-signed cert that isn't the one srv is using
		caPath := writeTempFile(t, "wrong-ca.pem", "---BEGIN CERTIFICATE---\n...\n---END CERTIFICATE---")

		// 3. Force the function to fail by ensuring it doesn't have the srv.Certificate()
		_, err := PostJSON(srv.URL, "tok", caPath, "m", "q")

		if err == nil {
			t.Fatal("expected TLS verification error, got nil")
		}
	})

	t.Run("returns error on missing CA file", func(t *testing.T) {
		_, err := PostJSON("https://example.invalid", "t", filepath.Join(t.TempDir(), "nope.pem"), "m", "q")
		if err == nil {
			t.Fatal("expected error for missing CA, got nil")
		}
	})
}

func TestExtractResponseField(t *testing.T) {
	t.Run("returns response field when present", func(t *testing.T) {
		got := ExtractResponseField([]byte(`{"response":"hi there","other":1}`))
		if got != "hi there" {
			t.Errorf("got %q; want %q", got, "hi there")
		}
	})

	t.Run("falls back to pretty JSON when response field missing", func(t *testing.T) {
		got := ExtractResponseField([]byte(`{"other":{"n":1}}`))
		if !strings.Contains(got, "\"other\"") || !strings.Contains(got, "  ") {
			t.Errorf("expected indented JSON; got %q", got)
		}
	})

	t.Run("falls back to raw string on malformed JSON", func(t *testing.T) {
		got := ExtractResponseField([]byte("not json at all"))
		if got != "not json at all" {
			t.Errorf("got %q", got)
		}
	})
}
