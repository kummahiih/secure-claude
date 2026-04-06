package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

const testToken = "test-token"

func newTestServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	mux := setupRouter(testToken, dir)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, dir
}

func doIngest(t *testing.T, srv *httptest.Server, ev map[string]interface{}) {
	t.Helper()
	b, _ := json.Marshal(ev)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/ingest", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("ingest: expected 200, got %d", resp.StatusCode)
	}
}

func getSummary(t *testing.T, srv *httptest.Server, sessionID string) SessionSummary {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/sessions/"+sessionID+"/summary", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("summary: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("summary: expected 200, got %d", resp.StatusCode)
	}
	var s SessionSummary
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	return s
}

// --- Summary: new event types ---

func TestSummaryFileReadCount(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "s1", "event_type": "file_read", "path": "foo.py", "size_bytes": 100,
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s1", "event_type": "file_read", "path": "bar.py", "size_bytes": 200,
	})

	sum := getSummary(t, srv, "s1")
	if sum.ToolCounts["file_read"] != 2 {
		t.Errorf("expected file_read=2, got %d", sum.ToolCounts["file_read"])
	}
}

func TestSummaryTestRunCount(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "s2", "event_type": "test_run", "exit_code": 0, "output_size_bytes": 50,
	})

	sum := getSummary(t, srv, "s2")
	if sum.ToolCounts["test_run"] != 1 {
		t.Errorf("expected test_run=1, got %d", sum.ToolCounts["test_run"])
	}
}

func TestSummaryGitOpCount(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "s3", "event_type": "git_op", "operation": "git_commit", "duration_ms": 42,
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s3", "event_type": "git_op", "operation": "git_status",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s3", "event_type": "git_op", "operation": "git_add",
	})

	sum := getSummary(t, srv, "s3")
	if sum.ToolCounts["git_op"] != 3 {
		t.Errorf("expected git_op=3, got %d", sum.ToolCounts["git_op"])
	}
}

func TestSummaryMixedEventTypes(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "s4", "event_type": "file_read", "path": "a.py",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s4", "event_type": "test_run", "exit_code": 1,
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s4", "event_type": "git_op", "operation": "git_log",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s4", "event_type": "llm_call",
		"model": "claude-3", "input_tokens": 100, "output_tokens": 50,
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "s4", "event_type": "tool_call", "tool_name": "read_workspace_file",
	})

	sum := getSummary(t, srv, "s4")
	if sum.ToolCounts["file_read"] != 1 {
		t.Errorf("expected file_read=1, got %d", sum.ToolCounts["file_read"])
	}
	if sum.ToolCounts["test_run"] != 1 {
		t.Errorf("expected test_run=1, got %d", sum.ToolCounts["test_run"])
	}
	if sum.ToolCounts["git_op"] != 1 {
		t.Errorf("expected git_op=1, got %d", sum.ToolCounts["git_op"])
	}
	if sum.LLMCalls != 1 {
		t.Errorf("expected llm_calls=1, got %d", sum.LLMCalls)
	}
	if sum.ToolCounts["read_workspace_file"] != 1 {
		t.Errorf("expected read_workspace_file=1, got %d", sum.ToolCounts["read_workspace_file"])
	}
}

func TestSummaryEmptySession(t *testing.T) {
	srv, _ := newTestServer(t)
	sum := getSummary(t, srv, "nonexistent")
	if sum.ToolCounts == nil {
		t.Error("expected non-nil ToolCounts")
	}
	if sum.LLMCalls != 0 {
		t.Errorf("expected 0 llm_calls, got %d", sum.LLMCalls)
	}
}

// --- Auth ---

func TestIngestUnauthorized(t *testing.T) {
	srv, _ := newTestServer(t)
	b, _ := json.Marshal(map[string]interface{}{"session_id": "s", "event_type": "file_read"})
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/ingest", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestSummaryUnauthorized(t *testing.T) {
	srv, _ := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/sessions/s1/summary", nil)
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// --- Health ---

func TestHealth(t *testing.T) {
	srv, _ := newTestServer(t)
	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

// --- Token breakdown: turn_number and cache_creation_tokens ---

func getTokens(t *testing.T, srv *httptest.Server, sessionID string) []TokenRecord {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/sessions/"+sessionID+"/tokens", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("tokens: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("tokens: expected 200, got %d", resp.StatusCode)
	}
	var out struct {
		TokenBreakdown []TokenRecord `json:"token_breakdown"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode tokens: %v", err)
	}
	return out.TokenBreakdown
}

func TestTokensTurnNumberRoundTrip(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "tn1", "event_type": "llm_call",
		"model": "claude-opus-4", "input_tokens": 100, "output_tokens": 50,
		"cache_creation_tokens": 10, "turn_number": 1,
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "tn1", "event_type": "llm_call",
		"model": "claude-opus-4", "input_tokens": 200, "output_tokens": 80,
		"cache_creation_tokens": 20, "turn_number": 2,
	})

	records := getTokens(t, srv, "tn1")
	if len(records) != 2 {
		t.Fatalf("expected 2 records, got %d", len(records))
	}
	if records[0].TurnNumber != 1 {
		t.Errorf("record[0]: expected turn_number=1, got %d", records[0].TurnNumber)
	}
	if records[0].CacheCreationTokens != 10 {
		t.Errorf("record[0]: expected cache_creation_tokens=10, got %d", records[0].CacheCreationTokens)
	}
	if records[1].TurnNumber != 2 {
		t.Errorf("record[1]: expected turn_number=2, got %d", records[1].TurnNumber)
	}
	if records[1].CacheCreationTokens != 20 {
		t.Errorf("record[1]: expected cache_creation_tokens=20, got %d", records[1].CacheCreationTokens)
	}
}

// --- File dedup ---

func getFileDedup(t *testing.T, srv *httptest.Server, sessionID string, wantStatus int) []FileDedupEntry {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/sessions/"+sessionID+"/file-dedup", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("file-dedup: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != wantStatus {
		t.Fatalf("file-dedup: expected %d, got %d", wantStatus, resp.StatusCode)
	}
	if wantStatus != http.StatusOK {
		return nil
	}
	var entries []FileDedupEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		t.Fatalf("decode file-dedup: %v", err)
	}
	return entries
}

func TestFileDedupBasic(t *testing.T) {
	srv, _ := newTestServer(t)

	// Two reads of the same file (sha256 = "abc123"), one unique.
	doIngest(t, srv, map[string]interface{}{
		"session_id": "fd1", "event_type": "file_read",
		"path": "a.go", "size_bytes": 4000, "sha256": "abc123",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "fd1", "event_type": "file_read",
		"path": "a.go", "size_bytes": 4000, "sha256": "abc123",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "fd1", "event_type": "file_read",
		"path": "b.go", "size_bytes": 1000, "sha256": "def456",
	})

	entries := getFileDedup(t, srv, "fd1", http.StatusOK)
	if len(entries) != 1 {
		t.Fatalf("expected 1 dedup entry, got %d", len(entries))
	}
	e := entries[0]
	if e.SHA256 != "abc123" {
		t.Errorf("expected sha256=abc123, got %s", e.SHA256)
	}
	if e.ReadCount != 2 {
		t.Errorf("expected read_count=2, got %d", e.ReadCount)
	}
	if e.DuplicateReads != 1 {
		t.Errorf("expected duplicate_reads=1, got %d", e.DuplicateReads)
	}
	if e.EstWastedTokens != 1000 {
		t.Errorf("expected est_wasted_tokens=1000, got %d", e.EstWastedTokens)
	}
}

func TestFileDedupNotFound(t *testing.T) {
	srv, _ := newTestServer(t)
	getFileDedup(t, srv, "no-such-session", http.StatusNotFound)
}

func TestFileDedupNoDuplicates(t *testing.T) {
	srv, _ := newTestServer(t)

	doIngest(t, srv, map[string]interface{}{
		"session_id": "fd2", "event_type": "file_read",
		"path": "a.go", "size_bytes": 500, "sha256": "aaa",
	})
	doIngest(t, srv, map[string]interface{}{
		"session_id": "fd2", "event_type": "file_read",
		"path": "b.go", "size_bytes": 600, "sha256": "bbb",
	})

	entries := getFileDedup(t, srv, "fd2", http.StatusOK)
	if len(entries) != 0 {
		t.Errorf("expected 0 dedup entries, got %d", len(entries))
	}
}

func TestFileDedupUnauthorized(t *testing.T) {
	srv, _ := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/sessions/s1/file-dedup", nil)
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
