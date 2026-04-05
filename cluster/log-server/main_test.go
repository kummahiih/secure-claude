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
