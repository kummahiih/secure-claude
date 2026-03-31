package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// cleanEnv returns a copy of the environment with all sensitive tokens removed.
// This ensures subprocess tests start from a known-clean state.
func cleanEnv(extra ...string) []string {
	strip := map[string]bool{
		"ANTHROPIC_API_KEY": true,
		"CLAUDE_API_TOKEN":  true,
		"DYNAMIC_AGENT_KEY": true,
		"MCP_API_TOKEN":     true,
		"PLAN_API_TOKEN":    true,
		"TESTER_API_TOKEN":  true,
		"GIT_API_TOKEN":     true,
		"LOG_API_TOKEN":     true,
	}
	var env []string
	for _, e := range os.Environ() {
		key := strings.SplitN(e, "=", 2)[0]
		if !strip[key] {
			env = append(env, e)
		}
	}
	return append(env, extra...)
}

// --- verifyToken ---

func TestVerifyToken_Valid(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Authorization", "Bearer secret123")
	if !verifyToken(r, "secret123") {
		t.Fatal("expected token to be valid")
	}
}

func TestVerifyToken_Invalid(t *testing.T) {
	cases := []struct {
		name   string
		header string
	}{
		{"wrong token", "Bearer wrong"},
		{"no header", ""},
		{"no bearer prefix", "secret123"},
		{"length mismatch", "Bearer short"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.header != "" {
				r.Header.Set("Authorization", tc.header)
			}
			if verifyToken(r, "secret123") {
				t.Fatal("expected token to be invalid")
			}
		})
	}
}

// --- sanitizeID ---

func TestSanitizeID(t *testing.T) {
	cases := []struct{ in, want string }{
		{"abc-123_DEF", "abc-123_DEF"},
		{"../etc/passwd", "___etc_passwd"},
		{"hello world", "hello_world"},
		{"", ""},
	}
	for _, tc := range cases {
		got := sanitizeID(tc.in)
		if got != tc.want {
			t.Errorf("sanitizeID(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// --- health endpoint ---

func TestHealthEndpoint(t *testing.T) {
	mux := setupRouter("tok", t.TempDir())
	r := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("health: got %d, want 200", w.Code)
	}
}

// --- ingest + query round-trip ---

func TestIngestAndQuery(t *testing.T) {
	dir := t.TempDir()
	const tok = "testtoken"
	mux := setupRouter(tok, dir)

	ev := LogEvent{
		SessionID: "sess1",
		EventType: "llm_call",
		Model:     "claude-opus-4",
		InputTokens:  100,
		OutputTokens: 50,
		DurationMs:   300,
	}
	body, _ := json.Marshal(ev)

	// POST /ingest
	r := httptest.NewRequest(http.MethodPost, "/ingest", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+tok)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("ingest: got %d, want 200; body: %s", w.Code, w.Body.String())
	}

	// GET /sessions
	r = httptest.NewRequest(http.MethodGet, "/sessions", nil)
	r.Header.Set("Authorization", "Bearer "+tok)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("list sessions: got %d", w.Code)
	}
	var listResp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&listResp)
	sessions := listResp["sessions"].([]interface{})
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}

	// GET /sessions/sess1/summary
	r = httptest.NewRequest(http.MethodGet, "/sessions/sess1/summary", nil)
	r.Header.Set("Authorization", "Bearer "+tok)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("summary: got %d", w.Code)
	}
	var summary SessionSummary
	json.NewDecoder(w.Body).Decode(&summary)
	if summary.LLMCalls != 1 {
		t.Errorf("expected 1 LLM call, got %d", summary.LLMCalls)
	}
	if summary.TotalInputTokens != 100 {
		t.Errorf("expected 100 input tokens, got %d", summary.TotalInputTokens)
	}

	// POST /sessions/sess1/query
	qBody, _ := json.Marshal(QueryRequest{EventType: "llm_call"})
	r = httptest.NewRequest(http.MethodPost, "/sessions/sess1/query", bytes.NewReader(qBody))
	r.Header.Set("Authorization", "Bearer "+tok)
	r.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("query: got %d", w.Code)
	}
	var qResp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&qResp)
	evts := qResp["events"].([]interface{})
	if len(evts) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evts))
	}

	// GET /sessions/sess1/tokens
	r = httptest.NewRequest(http.MethodGet, "/sessions/sess1/tokens", nil)
	r.Header.Set("Authorization", "Bearer "+tok)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("tokens: got %d", w.Code)
	}
	var tResp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&tResp)
	breakdown := tResp["token_breakdown"].([]interface{})
	if len(breakdown) != 1 {
		t.Fatalf("expected 1 token record, got %d", len(breakdown))
	}
}

func TestUnauthorizedRequests(t *testing.T) {
	mux := setupRouter("realtoken", t.TempDir())
	endpoints := []struct {
		method, path string
	}{
		{http.MethodPost, "/ingest"},
		{http.MethodGet, "/sessions"},
		{http.MethodGet, "/sessions/x/summary"},
		{http.MethodPost, "/sessions/x/query"},
		{http.MethodGet, "/sessions/x/tokens"},
	}
	for _, ep := range endpoints {
		var body *bytes.Reader
		if ep.method == http.MethodPost {
			body = bytes.NewReader([]byte("{}"))
		} else {
			body = bytes.NewReader(nil)
		}
		r := httptest.NewRequest(ep.method, ep.path, body)
		r.Header.Set("Authorization", "Bearer wrongtoken")
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: got %d, want 401", ep.method, ep.path, w.Code)
		}
	}
}

// --- entrypoint.sh isolation checks ---

func TestEntrypointRejectsForbiddenVars(t *testing.T) {
	forbidden := []string{
		"ANTHROPIC_API_KEY",
		"MCP_API_TOKEN",
		"PLAN_API_TOKEN",
		"TESTER_API_TOKEN",
		"GIT_API_TOKEN",
		"CLAUDE_API_TOKEN",
		"DYNAMIC_AGENT_KEY",
	}
	for _, v := range forbidden {
		t.Run(v, func(t *testing.T) {
			cmd := exec.Command("sh", "./entrypoint.sh")
			cmd.Env = cleanEnv(v+"=secret-value", "LOG_API_TOKEN=dummy")
			out, _ := cmd.CombinedOutput()
			code := cmd.ProcessState.ExitCode()
			if code == 0 {
				t.Errorf("expected non-zero exit when %s is set, got 0; output: %s", v, out)
			}
			if !strings.Contains(string(out), "FATAL") {
				t.Errorf("expected FATAL in output when %s is set, got: %s", v, out)
			}
		})
	}
}

func TestEntrypointRejectsMissingLogToken(t *testing.T) {
	cmd := exec.Command("sh", "./entrypoint.sh")
	cmd.Env = cleanEnv() // no LOG_API_TOKEN, no forbidden vars
	out, _ := cmd.CombinedOutput()
	code := cmd.ProcessState.ExitCode()
	if code == 0 {
		t.Errorf("expected non-zero exit without LOG_API_TOKEN; output: %s", out)
	}
	if !strings.Contains(string(out), "FATAL") {
		t.Errorf("expected FATAL in output; got: %s", out)
	}
}
