// Command plan is the Go reimplementation of plan.sh: it POSTs a
// {model, query} JSON document to the secure-claude cluster's /plan
// endpoint, prints the extracted response, then pretty-prints the most
// recent plans/plan-*.json file using the same glyphs and labels as
// the bash script.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"client"
)

func main() {
	if err := runPlan(os.Args[1:], os.Stdout, ".cluster_tokens.env", "./cluster/certs/ca.crt", "https://localhost:8443/plan", "plans"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// runPlan performs the /plan request flow and renders the latest plan
// file under plansDir. Factored out of main so unit tests can drive it
// against an httptest server and a temp directory.
func runPlan(args []string, stdout io.Writer, tokensPath, caPath, endpoint, plansDir string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: plan model \"Describe what you want to build\"")
	}
	model := args[0]
	query := args[1]

	if _, err := os.Stat(tokensPath); err != nil {
		return fmt.Errorf("%s not found; run ./run.sh first to generate tokens", tokensPath)
	}
	tokens, err := client.LoadTokens(tokensPath)
	if err != nil {
		return fmt.Errorf("load tokens: %w", err)
	}
	token := tokens["CLAUDE_API_TOKEN"]
	if token == "" {
		return fmt.Errorf("CLAUDE_API_TOKEN missing from %s", tokensPath)
	}

	body, err := client.PostJSON(endpoint, token, caPath, model, query)
	if err != nil {
		return err
	}

	fmt.Fprintln(stdout, "=== Claude's Planning Response ===")
	fmt.Fprintln(stdout, client.ExtractResponseField(body))
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "=== Current Plan ===")

	latest, err := newestPlanFile(plansDir)
	if err != nil || latest == "" {
		fmt.Fprintf(stdout, "No plan files found in %s/\n", plansDir)
		return nil
	}
	return renderPlan(stdout, latest)
}

// newestPlanFile returns the plans/plan-*.json file with the most
// recent ModTime, or "" if none exist.
func newestPlanFile(plansDir string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(plansDir, "plan-*.json"))
	if err != nil || len(matches) == 0 {
		return "", err
	}
	type entry struct {
		path string
		mod  int64
	}
	entries := make([]entry, 0, len(matches))
	for _, m := range matches {
		info, err := os.Stat(m)
		if err != nil {
			continue
		}
		entries = append(entries, entry{m, info.ModTime().UnixNano()})
	}
	if len(entries) == 0 {
		return "", nil
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].mod > entries[j].mod })
	return entries[0].path, nil
}

// renderPlan prints the plan JSON file in the same layout as plan.sh.
func renderPlan(stdout io.Writer, path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var plan struct {
		ID     string `json:"id"`
		Goal   string `json:"goal"`
		Status string `json:"status"`
		Tasks  []struct {
			ID     string   `json:"id"`
			Name   string   `json:"name"`
			Status string   `json:"status"`
			Files  []string `json:"files"`
		} `json:"tasks"`
	}
	if err := json.Unmarshal(raw, &plan); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Plan: %s\n", plan.ID)
	fmt.Fprintf(stdout, "Goal: %s\n", plan.Goal)
	fmt.Fprintf(stdout, "Status: %s\n", plan.Status)
	fmt.Fprintln(stdout)
	markers := map[string]string{
		"completed":   "✓",
		"current":     "→",
		"pending":     " ",
		"blocked":     "✗",
		"in_progress": "…",
	}
	for _, t := range plan.Tasks {
		marker, ok := markers[t.Status]
		if !ok {
			marker = "?"
		}
		fmt.Fprintf(stdout, "  [%s] %s: %s (%s)\n", marker, t.ID, t.Name, t.Status)
		if len(t.Files) > 0 {
			fmt.Fprintf(stdout, "      files: %s\n", strings.Join(t.Files, ", "))
		}
	}
	return nil
}
