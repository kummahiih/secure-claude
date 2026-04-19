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

func TestRunPlanUsage(t *testing.T) {
	var out bytes.Buffer
	err := runPlan(nil, &out, "unused", "unused", "unused", "unused")
	if err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("expected usage error, got %v", err)
	}
	err = runPlan([]string{"only-model"}, &out, "unused", "unused", "unused", "unused")
	if err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("expected usage error for single arg, got %v", err)
	}
}

func TestRunPlanNoPlansDir(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"response":"planned"}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	tokensPath := writeFile(t, dir, "tokens.env", "CLAUDE_API_TOKEN=sekret\n")
	caPath := writeFile(t, dir, "ca.pem", string(pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: srv.Certificate().Raw,
	})))
	missingPlans := filepath.Join(dir, "no-such-plans-dir")

	var out bytes.Buffer
	if err := runPlan([]string{"claude", "goal"}, &out, tokensPath, caPath, srv.URL, missingPlans); err != nil {
		t.Fatalf("runPlan: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, "=== Claude's Planning Response ===") {
		t.Errorf("missing planning response header: %q", s)
	}
	if !strings.Contains(s, "planned") {
		t.Errorf("missing response text: %q", s)
	}
	if !strings.Contains(s, "No plan files found in "+missingPlans+"/") {
		t.Errorf("missing fallback message: %q", s)
	}
}

func TestRunPlanRendersPlan(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer sekret" {
			t.Errorf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"response":"planned!"}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	tokensPath := writeFile(t, dir, "tokens.env", "CLAUDE_API_TOKEN=sekret\n")
	caPath := writeFile(t, dir, "ca.pem", string(pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: srv.Certificate().Raw,
	})))
	plansDir := filepath.Join(dir, "plans")
	if err := os.Mkdir(plansDir, 0o755); err != nil {
		t.Fatalf("mkdir plans: %v", err)
	}
	planJSON := `{
  "id": "plan-xyz",
  "goal": "test goal",
  "status": "active",
  "tasks": [
    {"id": "t1", "name": "done task", "status": "completed", "files": ["a.go"]},
    {"id": "t2", "name": "current task", "status": "current", "files": []},
    {"id": "t3", "name": "todo task", "status": "pending", "files": []},
    {"id": "t4", "name": "stuck task", "status": "blocked", "files": []},
    {"id": "t5", "name": "running task", "status": "in_progress", "files": []}
  ]
}`
	writeFile(t, plansDir, "plan-xyz.json", planJSON)

	var out bytes.Buffer
	if err := runPlan([]string{"claude", "hi"}, &out, tokensPath, caPath, srv.URL, plansDir); err != nil {
		t.Fatalf("runPlan: %v", err)
	}
	s := out.String()
	wantSubs := []string{
		"planned!",
		"=== Current Plan ===",
		"Plan: plan-xyz",
		"Goal: test goal",
		"Status: active",
		"[✓] t1: done task (completed)",
		"files: a.go",
		"[→] t2: current task (current)",
		"[ ] t3: todo task (pending)",
		"[✗] t4: stuck task (blocked)",
		"[…] t5: running task (in_progress)",
	}
	for _, w := range wantSubs {
		if !strings.Contains(s, w) {
			t.Errorf("output missing %q\nfull output:\n%s", w, s)
		}
	}
}
